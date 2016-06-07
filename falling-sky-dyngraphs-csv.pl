#! /usr/bin/env perl

# Create charts based on daily_summary

use Getopt::Long;
use POSIX strftime;
use IO::File;
use Socket6;
use Data::Dumper;
use JSON;
use DBI;
use strict;

$| = 1;

my ( $MirrorConfig, $PrivateConfig, $dbh, $midnight );

$ENV{"TZ"} = "UTC";

################################################################
# getopt                                                       #
################################################################

my ( $usage, %argv, %input ) = "";

%input = (
    "rescan=i"  => "rescan this many days (3)",
    "config=s"  => "config.js file (REQUIRED)",
    "sitedir=s" => "site directory(default: same as config)",
    "private=s" => "private.js file (default: same place as config.js)",
    "v|verbose" => "spew extra data to the screen",
    "h|help"    => "show option help"
);

my $result = GetOptions( \%argv, keys %input );
$argv{"rescan"} ||= 3;
if ( ( $argv{"config"} ) && ( !$argv{"private"} ) ) {
    $argv{"private"} = $argv{"config"};
    $argv{"private"} =~ s#[^/]+$#private.js#;
}
if ( !$argv{"sitedir"} ) {
    $argv{"sitedir"} = $argv{"config"};
    $argv{"sitedir"} =~ s#/[^/]+$##;    # Strip filename, keep rest
}

if ( ( !$result ) || ( !$argv{"config"} ) || ( $argv{h} ) ) {
    &showOptionsHelp;
    exit 0;
}

################################################################
# configs                                                      #
################################################################

sub get_file {
    my ($file) = @_;
    my $handle = new IO::File "<$file" or die "Could not open $file : $!";
    my $buffer;
    read $handle, $buffer, -s $file;
    close $handle;
    return $buffer;

}

sub get_config {
    my ( $file, $varname ) = @_;
    my $got = get_file($file);

    # Remove varname
    $got =~ s#^\s*$varname\s*=\s*##ms;

    # Remove comments like /* and */  and //
    $got =~ s#(/\*([^*]|[\r\n]|(\*+([^*/]|[\r\n])))*\*+/)|([\s\t](//).*)##mg;

    # And trailing commas
    $got =~ s/,\s*([\]}])/$1/mg;

    my $ref = decode_json($got);
    if ( !$ref ) {
        die "Could not json parse $file\n";
    }
    return $ref;
}

sub validate_private_config {
    my ($ref) = @_;
    die "Missing private.js: db password" unless ( $ref->{db}{password} );
    die "Missing private.js: db db"       unless ( $ref->{db}{db} );
    die "Missing private.js: db username" unless ( $ref->{db}{username} );
    die "Missing private.js: db host"     unless ( $ref->{db}{host} );
}

################################################################
# utilities                                                    #
################################################################

sub get_db_handle {
    my ($dbref) = @_;
    my $dsn =
      sprintf( "DBI:mysql:database=%s;host=%s", $dbref->{db}, $dbref->{host} );
    my $dbh = DBI->connect( $dsn, $dbref->{username}, $dbref->{password} );
    die "Failed to connect to mysql" unless ($dbh);
    return $dbh;
}

my %my_mkdir;

sub my_mkdir {
    my ($dir) = @_;
    return if ( $my_mkdir{$dir}++ );
    return if ( -d $dir );
    system( "mkdir", "-p", $dir );
    return if ( -d $dir );
    die "Unable to create $dir\: $!";

}

sub showOptionsHelp {
    my ( $left, $right, $a, $b, $key );
    my (@array);
    print "Usage: $0 [options] $usage\n";
    print "where options can be:\n";
    foreach $key ( sort keys(%input) ) {
        ( $left, $right ) = split( /[=:]/, $key );
        ( $a,    $b )     = split( /\|/,   $left );
        if ($b) {
            $left = "-$a --$b";
        }
        else {
            $left = "   --$a";
        }
        $left = substr( "$left" . ( ' ' x 20 ), 0, 20 );
        push( @array, "$left $input{$key}\n" );
    }
    print sort @array;
}

################################################################
# Prep daily and monthly summaries in the database             #
################################################################

sub update_daily_summary {
    my ($rescan) = @_;
    my $unix = $midnight - $rescan * 86400;
    while ( $unix <= $midnight ) {
        my $day   = strftime( '%Y-%m-%d', localtime $unix );
        my $start = "$day 00:00:00";
        my $stop  = "$day 23:59:59";
        print "Process:  $start  to $stop\n" if ( $argv{"v"} );
        $unix += 86400;

        my %byvalues;

        {
            my $sql_template =
"select status_a,status_aaaa,status_ds4,status_ds6,ip6,ip6,cookie,tokens from survey where timestamp >= ? and timestamp <= ?  order by timestamp;";
            my $sth = $dbh->prepare($sql_template);
            $sth->execute( $start, $stop ) or die $sth->errstr;

            while ( my $ref = $sth->fetchrow_hashref() ) {
                print "." if ( $argv{"v"} );
                my $cookie      = ${$ref}{"cookie"};
                my $tokens      = ${$ref}{"tokens"};
                my $ip4         = ${$ref}{"ip4"};
                my $ip6         = ${$ref}{"ip6"};
                my $status_a    = ${$ref}{"status_a"};
                my $status_aaaa = ${$ref}{"status_aaaa"};
                my $status_ds4  = ${$ref}{"status_ds4"};
                my $status_ds6  = ${$ref}{"status_ds6"};

                $tokens =
                  check_results($ref);    # Ignore prior state.  Re-evaluate.

                $byvalues{$cookie} = $tokens;
            } ## end while ( my $ref = $sth->fetchrow_hashref() )
            $sth->finish();
            print "\n" if ( $argv{"v"} );

        }

        # Now do something with %bycookie;
        # invert
        my %bystatus;
        foreach my $key ( keys %byvalues ) {
            $bystatus{ $byvalues{$key} }++;
        }

#        # Delete the previous count for this date, in preparation to update it.
#        {
#            my $sql_template = "delete from daily_summary where datestamp = ?;";
#            my $sth          = $dbh->prepare($sql_template);
#            $sth->execute($day) or die $sth->errstr;
#            $sth->finish();
#
#        }

        # Insert new records
        {
            my $sql_template =
"replace into daily_summary (datestamp,total,tokens) values (?,?,?);";
            my $sth = $dbh->prepare($sql_template);
            foreach my $tokens ( keys %bystatus ) {
                my $count = $bystatus{$tokens};
                $sth->execute( $day, $count, $tokens ) or die $sth->errstr;
                print "$sql_template ($day, $count, $tokens)\n"
                  if ( $argv{"v"} );
            }
            $sth->finish();
        }
    } ## end while ( $unix <= $midnight )
} ## end sub update_daily_summary

sub update_monthly_summary {
    my ($rescan) = @_;
    my $unix = $midnight - $rescan * 86400;
    my %did_month;
    while ( $unix <= $midnight + 86400 ) {
        my $month = strftime( '%Y-%m', localtime $unix );
        $unix += 86400;
        next if ( $did_month{$month}++ );    # Don't want the repeat business.
        my $start = "$month-01";
        my $stop;
        {
            my $sql_template = "SELECT LAST_DAY(?);";
            my $sth          = $dbh->prepare($sql_template);
            $sth->execute($start) or die $sth->errstr;
            ($stop) = $sth->fetchrow_array;
            $sth->finish();

        }

        print "Process:  $start  to $stop\n" if ( $argv{"v"} );

        my %bystatus;

        {
            my $sql_template =
"select total,tokens from daily_summary where datestamp >= ? and datestamp <= ?;";
            my $sth = $dbh->prepare($sql_template);
            $sth->execute( $start, $stop ) or die $sth->errstr;

            while ( my $ref = $sth->fetchrow_hashref() ) {
                my $tokens = ${$ref}{tokens};
                my $total  = ${$ref}{total};
                $bystatus{$tokens} += $total;
            }
            $sth->finish();

        }

        # Delete the previous count for this date, in preparation to update it.
        {
            my $sql_template =
              "delete from monthly_summary where datestamp = ?;";
            my $sth = $dbh->prepare($sql_template);
            $sth->execute($stop)  or die $sth->errstr;
            $sth->execute($start) or die $sth->errstr;
            $sth->finish();

        }

        # Insert new records
        {
            my $sql_template =
"insert into monthly_summary (datestamp,total,tokens) values (?,?,?);";
            my $sth = $dbh->prepare($sql_template);
            foreach my $tokens ( keys %bystatus ) {
                my $count = $bystatus{$tokens};
                $sth->execute( $stop, $count, $tokens ) or die $sth->errstr;

            }
            $sth->finish();
        }
    } ## end while ( $unix <= $midnight + 86400 )
} ## end sub update_monthly_summary

################################################################
# Check results                                                #
################################################################

my %states = (
    "a aaaa ds4 ds6" => "status",
    "oooo"           => "Confused",
    "ooob"           => "Dual Stack - IPv4 Preferred",
    "oobo"           => "Dual Stack - IPv6 Preferred",
    "oobb"           => "Broken DS",
    "oboo"           => "Confused",
    "obob"           => "IPv4 only",
    "obbo" => "Dual Stack - IPv6 Preferred",    # Whoa.  What's with that one?
    "obbb" => "Broken DS",
    "booo" => "Confused",
    "boob" => "Dual Stack - IPv4 Preferred",    # Whoa. What's with that one?
    "bobo" => "IPv6 only",
    "bobb" => "Broken DS",
    "bboo" => "Web Filter",
    "bbob" => "Web Filter",
    "bbbo" => "Web Filter",
    "bbbb" => "Web Filter",
);

sub check_results {
    my $ref = shift @_;

    my $status_a    = ${$ref}{"status_a"};
    my $status_aaaa = ${$ref}{"status_aaaa"};
    my $status_ds4  = ${$ref}{"status_ds4"};
    my $status_ds6  = ${$ref}{"status_ds6"};

    my $lookup =
        substr( $status_a, 0, 1 )
      . substr( $status_aaaa, 0, 1 )
      . substr( $status_ds4,  0, 1 )
      . substr( $status_ds6,  0, 1 );

    $lookup =~ s/s/o/g;    # Slow? treat as OK for this
    $lookup =~ s/t/b/g;    # Timeout? treat as bad for this
    my $token = $states{$lookup};

    #    print "$lookup $token\n" if ($argv{"v"});

    if ( !$token ) {
        $token ||= "Missing";

#        print join( "\t", $lookup, $status_a, $status_aaaa, $status_ds4, $status_ds6, $token ) . "\n";
    }

    return $token;
} ## end sub check_results

################################################################
# rrd-generate-db                                              #
################################################################

sub generate_data {
    my ($rescan) = @_;
    my $start_date =
      strftime( '%Y-%m-%d', gmtime( $midnight - $rescan * 86400 ) );
    my $stop_date = strftime( '%Y-%m-%d', gmtime( $midnight + 1 * 86400 ) );
    my $dir = $argv{"sitedir"};

    if ( ( ( $start_date cmp "2010-05-01" ) < 0 ) ) {
        $start_date = "2010-05-01";
    }
    my %buckets;
    my %dates;
    {
        my $sql_template =
"select unix_timestamp(datestamp) as unixtime, tokens, total   from daily_summary where datestamp >= ? and datestamp <= ?  order by unixtime;";
        my $sth = $dbh->prepare($sql_template);
        $sth->execute( $start_date, $stop_date ) or die $sth->errstr;

        while ( my $ref = $sth->fetchrow_hashref() ) {
            my $unixtime = ${$ref}{"unixtime"};
            my $total    = ${$ref}{"total"};

            my $bucket = ${$ref}{"tokens"};
            next if ( $bucket eq "skip" );
            next if ( $bucket eq "Missing" );
            if ( $argv{"v"} ) {

#                print STDERR "Unclear: ${$ref}{tokens}\n" if ( $bucket =~ /unclear/i );
            }
            $buckets{$bucket}          += $total;
            $buckets{"total"}          += $total;
            $dates{$unixtime}{$bucket} += $total;
            $dates{$unixtime}{"total"} += $total;
        }
        $sth->finish();
    }

    my @dates   = sort keys %dates;
    my @buckets = sort keys %buckets;

    # Make sure these are each created.
    my @buckets = (
        "IPv4 only",
        "IPv6 only",
        "Dual Stack - IPv4 Preferred",
        "Dual Stack - IPv6 Preferred",
        "Broken DS",
        "Confused",
        "Missing",
        "Web Filter",
        "total"
    );

    {
        my $filename = "$dir/graphdata_100.csv";
        my $fh       = IO::File->new(">$filename.new")
          or die "failed to create $filename.new: $!";

        my $legend = join( ",", grep( $_ ne "total", @buckets ) );
        print $fh "X,$legend\n";

        foreach my $date (@dates) {
            my $d = strftime( '%Y-%m-%d', gmtime $date );
            next if ( $d =~ m/2010-03-31/ );
            my @val = map( $dates{$date}{$_}, grep( $_ ne "total", @buckets ) );
            my $total = $dates{$date}{"total"};
            if ( $total > 0 ) {
                foreach my $val (@val) {
                    $val = sprintf( "%.2f", 100.00 * $val / $total );
                }
            }
            my $val = join( ",", @val );
            print $fh "$d,$val\n";
        }
        close $fh;
        rename( "$filename.new", "$filename" )
          or die "Rename $filename.new $filename: $!";

    }

    {
        my $filename = "$dir/graphdata.csv";
        my $fh       = IO::File->new(">$filename.new")
          or die "failed to create $filename.new: $!";

        my $legend = join( ",", @buckets );
        print $fh "X,$legend\n";

        foreach my $date (@dates) {
            my $d = strftime( '%Y-%m-%d', gmtime $date );
            next if ( $d =~ m/2010-03-31/ );
            my @val = map( $dates{$date}{$_}, @buckets );
            my $val = join( ",", @val );
            print $fh "$d,$val\n";
        }
        close $fh;
        rename( "$filename.new", "$filename" )
          or die "Rename $filename.new $filename: $!";

    }

} ## end sub generate_rrd_db

################################################################
# main                                                         #
################################################################

$midnight = int( time / 86400 ) * 86400;

$MirrorConfig  = get_config( $argv{"config"},  "MirrorConfig" );
$PrivateConfig = get_config( $argv{"private"}, "PrivateConfig" );
validate_private_config($PrivateConfig);
$dbh        = get_db_handle( $PrivateConfig->{db} );
$DB::single = 1;
update_daily_summary( $argv{"rescan"} );
update_monthly_summary( $argv{"rescan"} );
generate_data(600);

##  dygraphs.com - looks pretty cool - but not flexible in terms of mapping data to graph
#     whatever we do in csv, will "stick"

