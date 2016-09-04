#! /usr/bin/env perl

# Create charts based on daily_summary

use Getopt::Long;
use POSIX strftime;
use IO::File;
use Socket6;
use Data::Dumper;
use JSON;
use RRDs;
use DBI;
use strict;

$| = 1;

my ( $MirrorConfig, $PrivateConfig, $dbh, %blacklisted, $midnight );

# %blacklisted is not implemented at the moment.

$ENV{"TZ"} = "UTC";

################################################################
# getopt                                                       #
################################################################

my ( $usage, %argv, %input ) = "";

%input = (
           "rescan=i"  => "rescan this many days (3)",
           "config=s"  => "config.js file (REQUIRED)",
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
    die "Missing private.js: paths rrd"   unless ( $ref->{paths}{rrd} );
    die "Missing private.js: paths png"   unless ( $ref->{paths}{png} );
}

################################################################
# utilities                                                    #
################################################################

sub get_db_handle {
    my ($dbref) = @_;
    my $dsn = sprintf( "DBI:mysql:database=%s;host=%s", $dbref->{db}, $dbref->{host} );
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
        } else {
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

                next if ( exists $blacklisted{$ip4} );
                next if ( exists $blacklisted{$ip6} );
                if ($ip6) {
                    my $p = prefix( $ip6, 64 );
                    next if ( exists $blacklisted{$p} );
                }

                $tokens = check_results($ref);    # Ignore prior state.  Re-evaluate.

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

        # Delete the previous count for this date, in preparation to update it.
        {
            my $sql_template = "delete from daily_summary where datestamp = ?;";
            my $sth          = $dbh->prepare($sql_template);
            $sth->execute($day) or die $sth->errstr;
            $sth->finish();

        }

        # Insert new records
        {
            my $sql_template = "insert into daily_summary (datestamp,total,tokens) values (?,?,?);";
            my $sth          = $dbh->prepare($sql_template);
            foreach my $tokens ( keys %bystatus ) {
                my $count = $bystatus{$tokens};
                $sth->execute( $day, $count, $tokens ) or die $sth->errstr;
                print "$sql_template ($day, $count, $tokens)\n" if ( $argv{"v"} );
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
            my $sql_template = "select total,tokens from daily_summary where datestamp >= ? and datestamp <= ?;";
            my $sth          = $dbh->prepare($sql_template);
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
            my $sql_template = "delete from monthly_summary where datestamp = ?;";
            my $sth          = $dbh->prepare($sql_template);
            $sth->execute($stop)  or die $sth->errstr;
            $sth->execute($start) or die $sth->errstr;
            $sth->finish();

        }

        # Insert new records
        {
            my $sql_template = "insert into monthly_summary (datestamp,total,tokens) values (?,?,?);";
            my $sth          = $dbh->prepare($sql_template);
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
               "obbo"           => "Dual Stack - IPv6 Preferred",    # Whoa.  What's with that one?
               "obbb"           => "Broken DS",
               "booo"           => "Confused",
               "boob"           => "Dual Stack - IPv4 Preferred",    # Whoa. What's with that one?
               "bobo"           => "IPv6 only",
               "bobb"           => "Broken DS",
               "bboo"           => "Web Filter",
               "bbob"           => "Web Filter",
               "bbbo"           => "Web Filter",
               "bbbb"           => "Web Filter",
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

sub prefix {
    my ( $ip6, $bits ) = @_;
    my $p;
    my $i;
    die "prefix(ipv6,bits) - error, bits must be even multiple of 8" if ( $bits % 8 );
    my $bytes = $bits / 8;

    eval {
        my $i = inet_pton AF_INET6(), $ip6;
        $i =
          substr( substr( $i, 0, $bytes ) . "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 0, 16 );
        $p = inet_ntop( AF_INET6(), $i );
    };
    return $p;
}

################################################################
# rrd-generate-db                                              #
################################################################

sub generate_rrd_db {
    my ($rescan) = @_;
    my $start_date = strftime( '%Y-%m-%d', gmtime( $midnight - $rescan * 86400 ) );
    my $stop_date  = strftime( '%Y-%m-%d', gmtime( $midnight + 1 * 86400 ) );
    my $dir        = $PrivateConfig->{paths}{rrd};
    my_mkdir($dir);

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
    foreach ( "Broken DS", "Confused",
              "Dual Stack - IPv4 Preferred",
              "Dual Stack - IPv6 Preferred",
              "IPv4 only", "IPv6 only", "Missing", "Web Filter", "total" )
    {
        $buckets{$_} ||= 0;
    }

    foreach my $bucket ( keys %buckets ) {
        create_db( $dir, $bucket, $rescan );
        foreach my $date (@dates) {

            my $d = strftime( '%Y-%m-%d', gmtime $date );
            next if ( $d =~ m/2010-03-31/ );
            update_db( $dir, $bucket, $date, $dates{$date}{$bucket} );
        }
    }
} ## end sub generate_rrd_db

sub create_db {
    my ( $dir, $bucket, $rescan ) = @_;

    # dir = where to put the rrd file
    # bucket = how to name the rrd file

    my $filename = "$dir/$bucket.rrd";
    print "creating $filename\n" if ( -t STDOUT );

    my (@DS);
    my (@RRA);
    my ($start) = time - ( $rescan + 1 ) * 86400;
    $start = int( $start / 86400 ) * 86400;    # Start on a midnight boundary.

    my (@DS) = ("DS:count:GAUGE:86400:0:U");
    my (@RRA) = ( "RRA:LAST:0:1:5000", "RRA:LAST:0:7:5000" );    # Daily and Weekly, 5000 values each.

    RRDs::create( $filename, "-s", "86400", "-b", "$start", @DS, @RRA );
    my $error = RRDs::error;
    die $error if $error;
} ## end sub create_db

sub update_db {
    my ( $dir, $bucket, $date, $value ) = @_;
    my $filename = "$dir/$bucket.rrd";
    $value ||= 0;

    my $value2 = "$date\:$value";

    # Convert $date to a unix time stamp
#    print "update $filename $date $value\n" if ( $argv{"v"});
    RRDs::update( $filename, $value2 );
    my $error = RRDs::error;
    if ($error) {
        if ( $error =~ m#No such file# ) {
            create_db( $dir, $bucket );
            RRDs::update( $filename, $value2 );
            $error = RRDs::error;
        }
        if ($error) {
            print STDERR "ERROR: while attempting RRDs::update(\"$filename\",\"$value2\"): $error\n";
        }
    }
} ## end sub update_db

################################################################
# generate-rrd-images                                          #
################################################################

my ( @RRD_BASE_OPTS, @RRD_BASE_DEFS, %COLORS );

sub gen_graphs {
    my ( $short, $long ) = @_;
    base_setup();
    _generate_summary_area( "summary_area_days.png", $short );
    _generate_summary_area( "summary_area_year.png", $long );
    _generate_summary_line( "summary_line_days.png", $short );
    _generate_summary_line( "summary_line_year.png", $long );
    _generate_summary_pct( "summary_pct_days.png", $short );
    _generate_summary_pct( "summary_pct_year.png", $long );
    _generate_broken_pct( "summary_broken_days.png", $short );
    _generate_broken_pct( "summary_broken_year.png", $long );
}

sub base_setup {

# Baseline stuff - every image will have this as the starting point.
    my $DBDIR = $PrivateConfig->{paths}{rrd};

    @RRD_BASE_OPTS = ( "-a", "PNG", "-h", "200", "-w", "800" );
    @RRD_BASE_DEFS = grep( /./, split( /\n/, <<"EOF") );
DEF:Dual_Stack_pref_IPv4_raw=$DBDIR/Dual Stack - IPv4 Preferred.rrd:count:LAST
DEF:Dual_Stack_pref_IPv6_raw=$DBDIR/Dual Stack - IPv6 Preferred.rrd:count:LAST
DEF:IPv4_raw=$DBDIR/IPv4 only.rrd:count:LAST
DEF:IPv6_raw=$DBDIR/IPv6 only.rrd:count:LAST
DEF:Broken_raw=$DBDIR/Broken DS.rrd:count:LAST
DEF:Confused_raw=$DBDIR/Confused.rrd:count:LAST
DEF:WebFilter_raw=$DBDIR/Web Filter.rrd:count:LAST
DEF:Total_raw=$DBDIR/total.rrd:count:LAST
EOF

    foreach my $x (qw( Dual_Stack_pref_IPv4 Dual_Stack_pref_IPv6 IPv4 IPv6 Broken Confused WebFilter Total)) {
        push( @RRD_BASE_DEFS, "CDEF:${x}=${x}_raw,UN,0,${x}_raw,IF" );

    }
    push( @RRD_BASE_DEFS, grep( /./, split( /\n/, <<"EOF") ) );
CDEF:Dual_Stack=Dual_Stack_pref_IPv4,Dual_Stack_pref_IPv6,+
CDEF:untestable=Confused,WebFilter,+
CDEF:BrokenPercent=Broken,Total,/,100,*
CDEF:Zero=Total,UN,0,*
EOF

    foreach my $x (
                    qw( Dual_Stack_pref_IPv4 Dual_Stack_pref_IPv6 IPv4 IPv6 Broken Confused WebFilter Total
                    Dual_Stack untestable BrokenPercent Zero
                    )
      )
    {

        push( @RRD_BASE_DEFS, "CDEF:${x}_pct=${x},Total,/,100,*" );

        push( @RRD_BASE_DEFS, "VDEF:${x}_min=${x},MINIMUM" );
        push( @RRD_BASE_DEFS, "VDEF:${x}_max=${x},MAXIMUM" );
        push( @RRD_BASE_DEFS, "VDEF:${x}_avg=${x},AVERAGE" );
        push( @RRD_BASE_DEFS, "VDEF:${x}_pct_min=${x}_pct,MINIMUM" );
        push( @RRD_BASE_DEFS, "VDEF:${x}_pct_max=${x}_pct,MAXIMUM" );
        push( @RRD_BASE_DEFS, "VDEF:${x}_pct_avg=${x}_pct,AVERAGE" );
    }

    %COLORS = (
                Dual_Stack_pref_IPv4 => "00FFFF",
                Dual_Stack_pref_IPv6 => "00FF00",
                Dual_Stack           => "00FF00",
                IPv6                 => "FFFF00",
                IPv4                 => "8888FF",
                Broken               => "FF8888",
                Confused             => "aaaaaa",
                WebFilter            => "666666",
                untestable           => "888888",
                Total                => "000000",
                BrokenPercent        => "FF0000",
                Zero                 => "000000"
              );

} ## end sub base_setup

sub GenImage {
    my ( $name, @args ) = @_;
    my $IMGDIR = $PrivateConfig->{paths}{png};
    my_mkdir($IMGDIR);

    my ($ref) = RRDs::graph( "$IMGDIR/$name", @args );
    my $error = RRDs::error;
    if ($error) {
        print "error: $error\n";
        if ( -t STDOUT ) {
            print "$_\n" foreach (@args);
            print "\n";
        }
    }

#    print Dump($ref);
}

sub GenData {
    my ( $type, $cdef, $comment ) = @_;

    my $vdef = $cdef;
    $vdef =~ s/_raw$//;

    my $colordef = $cdef;
    $colordef =~ s/_raw$//;
    $colordef =~ s/_pct$//;

    if ( !exists $COLORS{$colordef} ) {
        die "Need \$COLORS{$colordef} defined\n";
    }
    my $STACK = "";
    $STACK = "STACK" if ( $type =~ /AREA/ );
    return ( grep( /./, split( /\n/, <<"EOF") ) );
COMMENT:$comment
${type}:${cdef}#$COLORS{$colordef}:$STACK
GPRINT:${vdef}_min:% 10.2lf
GPRINT:${vdef}_avg:% 10.2lf
GPRINT:${vdef}_max:% 10.2lf\\r
EOF
} ## end sub GenData

sub GenLine {
    return GenData( "LINE2", @_ );
}

sub GenArea {
    return GenData( "AREA", @_ );
}

sub time_range {
    my ( $start, $stop ) = @_;
    $start = strftime( '%d/%b/%Y', localtime $start );
    $stop  = strftime( '%d/%b/%Y', localtime $stop );
    return ("COMMENT:Time range\\: $start to $stop UTC\\r");
}

sub _generate_summary_area {
    my ( $filename, $days ) = @_;
    my $start  = $midnight - $days * 86400;
    my $stop   = $midnight - 86400;
    my $domain = $MirrorConfig->{"site"}{"name"};

    my @RRD_EXTRA_OPTS = ( "-s", $start, "-e", $stop );
    my @RRD_COMMANDS;
    push( @RRD_EXTRA_OPTS, "--title",          "Summary of test results / $domain" );
    push( @RRD_EXTRA_OPTS, "--vertical-label", "Per day" );
    push( @RRD_COMMANDS, time_range( $start, $stop ) );
    push( @RRD_COMMANDS, "COMMENT:Minimum     Average      Maximum\\r" );
    push( @RRD_COMMANDS, "LINE:Zero#000000" );
    push( @RRD_COMMANDS, GenArea( "IPv4_raw",             "IPv4 only" ) );
    push( @RRD_COMMANDS, GenArea( "Dual_Stack_pref_IPv4", "IPv4 and IPv6 (prefer IPv4)" ) )
      ;    # Not using "raw" for this one
    push( @RRD_COMMANDS, GenArea( "Dual_Stack_pref_IPv6", "IPv4 and IPv6 (prefer IPv6)" ) )
      ;    # Not using "raw" for this one
    push( @RRD_COMMANDS, GenArea( "IPv6_raw",      "IPv6 only" ) );
    push( @RRD_COMMANDS, GenArea( "Broken_raw",    "Detected Broken DS" ) );
    push( @RRD_COMMANDS, GenArea( "Confused_raw",  "Unrecognizable symptoms" ) );
    push( @RRD_COMMANDS, GenArea( "WebFilter_raw", "Browser filter blocked test" ) );

    push( @RRD_COMMANDS, "COMMENT: \\l" );
    push( @RRD_COMMANDS, "COMMENT: This is a 'stacked' graph; the top of the graph indicates test volume\\l" );
    push( @RRD_COMMANDS, "COMMENT: Graph is courtesy of http\\://$domain\\l" );

    GenImage( $filename, @RRD_BASE_OPTS, @RRD_EXTRA_OPTS, @RRD_BASE_DEFS, @RRD_COMMANDS );
} ## end sub _generate_summary_area

sub _generate_summary_line {
    my ( $filename, $days ) = @_;

    my $start  = $midnight - $days * 86400;
    my $stop   = $midnight - 86400;
    my $domain = $MirrorConfig->{"site"}{"name"};

    my @RRD_EXTRA_OPTS = ( "-s", $start, "-e", $stop );
    my @RRD_COMMANDS;
    push( @RRD_EXTRA_OPTS, "--title",          "Summary of test results / $domain" );
    push( @RRD_EXTRA_OPTS, "--vertical-label", "Per day" );
    push( @RRD_COMMANDS, time_range( $start, $stop ) );
    push( @RRD_COMMANDS, "COMMENT:Minimum     Average      Maximum\\r" );
    push( @RRD_COMMANDS, "LINE:Zero#000000" );
    push( @RRD_COMMANDS, GenLine( "IPv4_raw",             "IPv4 only" ) );
    push( @RRD_COMMANDS, GenLine( "Dual_Stack_pref_IPv4", "IPv4 and IPv6 (prefer IPv4)" ) )
      ;    # Not using "raw" for this one
    push( @RRD_COMMANDS, GenLine( "Dual_Stack_pref_IPv6", "IPv4 and IPv6 (prefer IPv6)" ) )
      ;    # Not using "raw" for this one
    push( @RRD_COMMANDS, GenLine( "IPv6_raw",      "IPv6 only" ) );
    push( @RRD_COMMANDS, GenLine( "Broken_raw",    "Detected Broken DS" ) );
    push( @RRD_COMMANDS, GenLine( "Confused_raw",  "Unrecognizable symptoms" ) );
    push( @RRD_COMMANDS, GenLine( "WebFilter_raw", "Browser filter blocked test" ) );

    push( @RRD_COMMANDS, "COMMENT: \\l" );
    push( @RRD_COMMANDS, "COMMENT: Graph is courtesy of http\\://$domain\\l" );
    GenImage( $filename, @RRD_BASE_OPTS, @RRD_EXTRA_OPTS, @RRD_BASE_DEFS, @RRD_COMMANDS );
} ## end sub _generate_summary_line

sub _generate_summary_pct {

    my ( $filename, $days ) = @_;
    my $start  = $midnight - $days * 86400;
    my $stop   = $midnight - 86400;
    my $domain = $MirrorConfig->{"site"}{"name"};

    my @RRD_EXTRA_OPTS = ( "-s", $start, "-e", $stop, "--upper-limit", 100, "--lower-limit", 0, "--rigid" );
    my @RRD_COMMANDS;
    push( @RRD_EXTRA_OPTS, "--title",          "Summary of test results / $domain" );
    push( @RRD_EXTRA_OPTS, "--vertical-label", "Per day" );
    push( @RRD_COMMANDS, time_range( $start, $stop ) );
    push( @RRD_COMMANDS, "COMMENT:Minimum     Average      Maximum\\r" );
    push( @RRD_COMMANDS, "LINE:Zero#000000" );
    push( @RRD_COMMANDS, GenArea( "IPv4_pct", "IPv4 only" ) );
    push( @RRD_COMMANDS, GenArea( "Dual_Stack_pref_IPv4_pct", "IPv4 and IPv6 (prefer IPv4)" ) )
      ;    # Not using "raw" for this one
    push( @RRD_COMMANDS, GenArea( "Dual_Stack_pref_IPv6_pct", "IPv4 and IPv6 (prefer IPv6)" ) )
      ;    # Not using "raw" for this one
    push( @RRD_COMMANDS, GenArea( "Broken_pct",    "Detected Broken DS" ) );
    push( @RRD_COMMANDS, GenArea( "Confused_pct",  "Unrecognizable symptoms" ) );
    push( @RRD_COMMANDS, GenArea( "WebFilter_pct", "Browser filter blocked test" ) );

    push( @RRD_COMMANDS, "COMMENT: \\l" );
    push( @RRD_COMMANDS, "COMMENT: This graph shows relative percentages of the total daily traffic\\l" );
    push( @RRD_COMMANDS, "COMMENT: Graph is courtesy of http\\://$domain\\l" );

    GenImage( $filename, @RRD_BASE_OPTS, @RRD_EXTRA_OPTS, @RRD_BASE_DEFS, @RRD_COMMANDS );
} ## end sub _generate_summary_pct

sub _generate_broken_pct {
    my ( $filename, $days ) = @_;

    my $start  = $midnight - $days * 86400;
    my $stop   = $midnight - 86400;
    my $domain = $MirrorConfig->{"site"}{"name"};

    my @RRD_EXTRA_OPTS = ( "-s", $start, "-e", $stop );
    my @RRD_COMMANDS;
    push( @RRD_EXTRA_OPTS, "--title",          "Broken users as percentage of all tested / $domain" );
    push( @RRD_EXTRA_OPTS, "--vertical-label", "Per day" );
    push( @RRD_COMMANDS, time_range( $start, $stop ) );
    push( @RRD_COMMANDS, "COMMENT:Minimum     Average      Maximum\\r" );
    push( @RRD_COMMANDS, "LINE:Zero#000000" );
    push( @RRD_COMMANDS, GenArea( "Broken_pct", "Detected Broken (pct)" ) );

    push( @RRD_COMMANDS, "COMMENT: \\l" );
    push( @RRD_COMMANDS, "COMMENT: Broken means browser times out trying to reach an IPv4+IPv6 site\\l" );
    push( @RRD_COMMANDS, "COMMENT: Graph is courtesy of http\\://$domain\\l" );

    GenImage( $filename, @RRD_BASE_OPTS, @RRD_EXTRA_OPTS, @RRD_BASE_DEFS, @RRD_COMMANDS );
} ## end sub _generate_broken_pct

################################################################
# main                                                         #
################################################################

$midnight = int( time / 86400 ) * 86400;

$MirrorConfig  = get_config( $argv{"config"},  "MirrorConfig" );
$PrivateConfig = get_config( $argv{"private"}, "PrivateConfig" );
validate_private_config($PrivateConfig);
$dbh = get_db_handle( $PrivateConfig->{db} );

update_daily_summary( $argv{"rescan"} );
update_monthly_summary( $argv{"rescan"} );
generate_rrd_db(600);
base_setup();
gen_graphs( 60, 600 );

