#! /usr/bin/perl

use strict;
use YAML::Syck;
use Time::HiRes qw(sleep);
use Digest::MD5 qw(md5_hex);

my %COLORS = (
    "box_delegated"      => "khaki",
    "box_both"  => "orange",
    "box_auth"        => "green",
    "box_dead"           => "gray50",
    "box_default"        => "khaki",
    "line_delegated"     => "black",
    "line_loop"          => "red",
    "line4" => "blue3",
    "line6" => "green4",
    "line_authoritative" => "black",
);

#glossary
#  bname, bip  -  "by" name and IP that is asking for a resource record
#  rname, rip  -  the name server we want to ask
#  qname, qtype - the name we want to ask for, and type (ie A or AAAA)

package Blot;

use Net::DNS::Resolver;
use YAML::Syck;

sub new {
    my $class = shift @_;
    my $self  = {};
    bless $self, $class;
    die "Bad # args for Blot::new(rname,rip,qname,qtype)\n"
      unless ( scalar @_ eq 4 );
    $self->{rname} = shift @_;    # Resolver Name
    $self->{rip}   = shift @_;    # Resolver IP
    $self->{qname} = shift @_;    # Query Name
    $self->{qtype} = shift @_;    # Query Type

    $self->{resolver} = new Net::DNS::Resolver(
        nameservers => [ $self->{rip} ],
        recurse     => 0,
        debug       => 0
    );

    $self->{tries}   = 0;
    $self->{retry}   = 3;
    $self->{retrans} = 2;

    $self->{sockets} = [];

    $self->send_once();
    return $self;

#  This object should generate the Question
#  This object should generate a serialized version of the whole set of arguements
#  This object should initiate a query
#
#  Object should when asked for results
#    - handle tries
#    - handle failures
#    - return answers
# Who (name, ip) asked?
# What (name, qtype) asked?
}

sub trace {
    my $self = shift;
    my $line = ( caller(1) )[2];
    printf STDERR "%s %i @_\n", $self->serialize(), $line;
}

sub send_once {
    my $self = shift @_;

    #    $self->trace("send_once()");

    $self->{tries}   = $self->{tries} + 1;
    $self->{timeout} = time() + $self->{retrans};
    my $socket = $self->{resolver}->bgsend( $self->{qname}, $self->{qtype} );
    push( @{ $self->{sockets} }, $socket );
}

sub can_retry {
    my $self = shift @_;

    #    $self->trace("can_retry()");
    return ( $self->{tries} <= $self->{retry} );
}

sub expired {
    my $self = shift @_;
    return ( time() >= $self->{timeout} );
}

sub socket_ready {
    my $self = shift @_;
    foreach my $socket ( @{ $self->{sockets} } ) {
        my $ready = $self->{resolver}->bgisready($socket);
        return $socket if $ready;
    }
    return;
}

# sub done will handle checking the socket,
# reading the socket, storing the answer,
# handling retries, expiration of this one object
sub done {
    my $self = shift @_;

    #    $self->trace("done()");
    if ( $self->{resolver} ) {
        my $ready = $self->socket_ready();
        if ($ready) {

            #            $self->trace("Trying to read socket $ready");
            my $packet = $self->{resolver}->bgread($ready);
#            foreach my $socket ( @{ $self->{sockets} } ) {
#                close($socket) if ($socket);
#            }
            $self->{packet}   = $packet;
            $self->{resolver} = undef;
            $self->{sockets}  = undef;
            return 1;
        }
        elsif ( $self->expired() ) {
            if ( $self->can_retry() ) {
                $self->send_once();
                return;
            }
            else {
                $self->{error} = "expired query";
#                printf STDERR "EXPIRED: %s\n", $self->{key};
#                printf STDERR Dump($self);
#                foreach my $socket ( @{ $self->{sockets} } ) {
#                    close($socket) if ($socket);
#                }
                $self->{packet}   = undef;
                $self->{resolver} = undef;
                $self->{sockets}  = undef;
                return 1;
            }
        }
        else {
            return;    # Just not done yet.
        }
    }
    else {
        return 1;
    }
}

sub read {
    my $self = shift @_;

    #    $self->trace("read()");
    return $self->{packet} if ( $self->done() );
    return;
}

sub serialize {
    my $self = shift @_;
    return main::serialize( $self->{rname}, $self->{rip}, $self->{qname},
        $self->{qtype} );
}

################################################################
################################################################
################################################################

package main;

my %questions;    # Things we have opened questions for
my %examined;     # Responses we examined already

# drawn lines, $relationships{$parent}{$child}=1
# auto-detects *immediate* loops only
my %relationships;

# Dot values filled in during examine()
my %answers;
my %colors;
my %shapes;

use Net::DNS::Resolver;

# Use bgsend to parallelize
# We wil need one Resolver object per question asked

my $qname = shift @ARGV || "ds.v6ns.test-ipv6.com";
my $qtype = shift @ARGV || "AAAA";

main();

# Our first ask will be against f.root-servers.net 192.5.5.241
sub main {

    dot_open();
    add_root_questions( $qname, $qtype );
    while (1) {
        my $moar = 0;
        my $done = 0;
        foreach my $key ( keys %questions ) {
            if ( $questions{$key}->done() ) {
                $done++;
                unless ( $examined{$key}++ ) {
                    examine( $questions{$key} );    # Check this guy out.
                    $moar++;                        # We want to keep looping
                }
            }
            else {
                $moar++;                            # We want to keep looping
            }
        }
        print STDERR "moar=$moar done=$done\n";
        last unless ($moar);
        sleep 0.05;
    }
    dot_link();
    dot_node();
    dot_close();
    dot_show();

}

sub dot_open {
    open( DOT, ">1.dot" );
    print DOT "digraph G {\n";
}

sub dot_close {
    print DOT "}\n";
    close DOT;
}

sub dot_link {
    foreach my $parent ( sort keys %relationships ) {
        foreach my $child ( sort keys %{ $relationships{$parent} } ) {

            # Bidirectional? Or just one way?
            my $hp = hash($parent);
            my $hc = hash($child);
            if ( $child eq $parent ) {

                # Authoritative, last stop
                print DOT
                  "$hp -> $hc [dir=both color=$COLORS{line_authoritative}]\n";
            }
            elsif (
                (
                       exists $relationships{$child}
                    && exists $relationships{$child}{$parent}
                )
              )
            {
                # bidi
                print DOT
                  "$hp -> $hc [dir=both color=\"$COLORS{line_loop}\"]\n";

            }
            else {
                # oneway
                my $linetype = "line_delegated";
                if (   ( exists $questions{$child} )
                    && ( $questions{$child}->{rip} ne $questions{$child}->{rname} )
                  )
                {
                    $linetype =
                      ( $questions{$child}->{rip} =~ /:/ ) ? "line6" : "line4";
                }
                
                print DOT "$hp -> $hc [color=\"$COLORS{$linetype}\"]\n";
            }
        }
    }
}

sub dot_show {
    print "show dot!";
    my $cmd = "dot -Tpdf -o1.pdf < 1.dot && open 1.pdf";
    print "% $cmd\n";
    system $cmd;
}

my %dot_node_helper_seen;

sub dot_node_helper {
    my ($key) = @_;
    unless ( $dot_node_helper_seen{$key}++ ) {
        my $hk     = hash($key);
        my $label  = $key;
        my $label2 = $answers{$key} || "";

        $label =~ s#[|]#<br/>@#;
        my $label2 = $answers{$key} || "";
        if ($label2) {
            $label2 =~ s#\n#<br/>#g;
            if ($label2 =~ /delegated/) {
            $label .= "<br/><i>$label2</i>";
            } else {
            $label .= "<br/><b>$label2</b>";
            }
        }
        my $color = $colors{$key} || "$COLORS{box_default}";
        my $shape = $shapes{$key} || "ellipse";

        print DOT
"$hk [label=<$label>, style=filled, fillcolor=$color, shape=$shape]\n";
    }
}

sub dot_node {
    my %seen;
    foreach my $parent ( keys %relationships ) {
        foreach my $child ( keys %{ $relationships{$parent} } ) {
            $seen{$parent} = 1;
            $seen{$child}  = 1;
        }
    }
    foreach my $key ( sort keys %seen ) {
        dot_node_helper($key);
    }

}

sub hash {
    my ($t) = @_;
    return "node" . md5_hex($t);
}

sub examine {
    my ($object) = @_;

    $object->trace("examine()");

    my $rname = $object->{rname};
    my $rip   = $object->{rip};
    my $qname = $object->{qname};
    my $qtype = $object->{qtype};


$DB::single=1 if ($rname =~ /v6ns1.test-ipv6.com/);


    my $packet = $object->read();
    my $key    = $object->{key};

    $shapes{$key} = "box";

    if ( !$packet ) {
        $object->trace("NO ANSWER");
        $answers{$key} = "NO RESPONSE";
        $colors{$key}  = "gray50";
        return;
    }

    my $header = $packet->header();
    my $rcode  = $header->rcode();
#    print STDERR "RCODE $rcode\n";

    if ( $rcode ne "NOERROR" ) {
        $answers{$key} = $rcode;
        $colors{$key}  = "red";
        return;
    }

    $object->trace("examine()");

    # we have a dns resolver response
    # Did we get what we asked for?
    # Did we get NS referals?

    foreach my $rr ( $packet->answer() ) {
        my @answers;
        if ( lc $rr->type eq lc $qtype ) {
            push( @answers, $rr->address );
        }
        if (@answers) {
            $answers{$key} = join( "\n", @answers );
            $colors{$key}  = "green";
            $shapes{$key}  = "ellipse";
        }
    }
#    print STDERR "\n\n\n";
#    print STDERR Dump($object);

    my %NS;
    foreach my $rr ( $packet->authority ) {
        next unless ( $rr->type eq "NS" );
        my $nsdname = $rr->nsdname;
        $NS{$nsdname} ||= []
          ; # Empty set means  "ask someone else" - we will follow with additionals
    }
    foreach my $rr ( $packet->additional ) {
        if ( ( $rr->type eq "A" ) || ( $rr->type eq "AAAA" ) ) {
            if ( exists $NS{ $rr->name } ) {
                push( @{ $NS{ $rr->name } }, $rr->address);
            }
        }
    }

    # For each %NS, either use the directed IP addresses (glue),
    # or if missing glue, find some IP addresses.. And then
    # start the background checks.
    my $counter = 0;
    foreach my $key ( keys %NS ) {
        if ( !scalar @{ $NS{$key} } ) {
            push( @{ $NS{$key} }, missing_glue($key ));
        }
        foreach my $val ( @{ $NS{$key} } ) {
            $counter +=
              add_question( $rname, $rip, $key, $val, $qname, $qtype );
        }
    }
    
    # What color should we make the box?
    my @NS = sort keys %NS;
    if ( ( scalar @NS eq 1 ) && ( $rname eq $NS[0] ) ) {
        $colors{$key} = $COLORS{box_auth};
    }
    elsif ( scalar @NS ) {
        if ( $answers{$key} ) {
            $DB::single = 1;
            $colors{$key} = $COLORS{box_both};
        }
        else {
            $answers{$key} = "delegated";
            $colors{$key}  = $COLORS{box_delegated};
        }
    }

    return $counter;
}

# Loop until nothing left to do
#  While we have questions to ask,
#  that are not redundant, ask.
#  While we have results, process them.
#  While we have timers running, resend if needed, or abandon.

sub serialize {
    my ( $rname, $rip, $qname, $qtype ) = @_;
    die "Bad call to main::serialize" unless ( scalar @_ eq 4 );
    return join( "|", $rname, $rip, $qname, $qtype );
}

sub add_question {
    my ( $bname, $bip, $rname, $rip, $qname, $qtype ) = @_;
    print STDERR "TRACE: add_question(@_);\n";

    $relationships{"$bname|$bip"}{"$rname|$rip"} = 1;

    my $key = join( "|", $rname, $rip );
    if ( exists $questions{$key} ) {
        return 0;
    }
    else {
        $questions{$key} = Blot->new( $rname, $rip, $qname, $qtype );
        $questions{$key}->{key} = $key;
        return 1;
    }
}

sub add_root_questions {
    my ( $qname, $qtype ) = @_;

   my @list = get_root();
   foreach my $root (@list) {
     add_question("start","start",$root,$root,$qname,$qtype);
   }
   return;

   # shortcut list?   
   
    add_question( "start", "start", "f.root-servers.net", "f.root-servers.net",
        $qname, $qtype );
    return;
}

my %missing_glue_cache;
sub missing_glue {
  my($name) = @_;
  if (exists $missing_glue_cache{$name}) {
    return @{$missing_glue_cache{$name}};
  }
  my @list;
  my $resolver = Net::DNS::Resolver->new( recurse=>1 );
  foreach my $qtype ("A","AAAA") {
    my $reply = $resolver->query($name,$qtype);
    if ($reply) {
      foreach my $rr ($reply->answer) {
        if (lc $rr->type eq lc $qtype) {
          push(@list, $rr->address);
        }
      }
    }
  }
#  print "missing_glue($name)=@list\n";
  $missing_glue_cache{$name} = \@list;
  return @list;  
}

sub get_root {
   my $resolver = Net::DNS::Resolver->new( recurse=>1 );
   my $reply = $resolver->query(".","NS");
   my @list;
   if ($reply) {
     foreach my $rr ($reply->answer) {
       if (lc $rr->type eq "ns") {
         push(@list, $rr->nsdname);
       }
     }
   }
#   print "get_root says @list\n";
   return @list;
}


__END__
a.root-servers.net.	9444	IN	A	198.41.0.4
b.root-servers.net.	251	IN	A	192.228.79.201
c.root-servers.net.	17759	IN	A	192.33.4.12
d.root-servers.net.	16801	IN	A	199.7.91.13
e.root-servers.net.	16809	IN	A	192.203.230.10
f.root-servers.net.	17011	IN	A	192.5.5.241
g.root-servers.net.	9488	IN	A	192.112.36.4
h.root-servers.net.	18172	IN	A	128.63.2.53
i.root-servers.net.	16116	IN	A	192.36.148.17
j.root-servers.net.	17801	IN	A	192.58.128.30
k.root-servers.net.	15729	IN	A	193.0.14.129
l.root-servers.net.	6634	IN	A	199.7.83.42
m.root-servers.net.	5139	IN	A	202.12.27.33

