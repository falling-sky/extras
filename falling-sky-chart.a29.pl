#! /usr/bin/env perl

# Create charts based on daily_summary

use Getopt::Long;
use POSIX strftime;
use IO::File;
use Data::Dumper;
use JSON;
use DBI;
use strict;

$| = 1;

my ($MirrorConfig, $PrivateConfig, $dbh);

# %blacklisted is not implemented at the moment.

$ENV{"TZ"}="UTC";


################################################################
# getopt                                                       #
################################################################


my ( $usage, %argv, %input ) = "";

$usage = " --config /path/to/site.js
Removes PII from an existing testipv6 database.
";


%input = (
           "config=s"  => "config.js file (REQUIRED)",
           "private=s" => "private.js file (default: same place as config.js)",
           "v|verbose" => "spew extra data to the screen",
           "h|help"    => "show option help"
         );

my $result = GetOptions( \%argv, keys %input );
if (($argv{"config"}) && (!$argv{"private"})) {
  $argv{"private"} = $argv{"config"};
  $argv{"private"} =~ s#[^/]+$#private.js#;
}

if ( ( !$result ) || (!$argv{"config"}) || ( $argv{h} ) ) {
    &showOptionsHelp;
    exit 0;
}



################################################################
# configs                                                      #
################################################################


sub get_file { 
 my($file) = @_;
 my $handle = new IO::File "<$file" or die "Could not open $file : $!";
 my $buffer;
 read $handle, $buffer, -s $file;
 close $handle;
 return $buffer;
 
}

sub get_config {
  my($file,$varname) = @_;
  my $got = get_file($file);

  # Remove varname
  $got =~ s#^\s*$varname\s*=\s*##ms;
  
  # Remove comments like /* and */  and //
  $got =~ s#(/\*([^*]|[\r\n]|(\*+([^*/]|[\r\n])))*\*+/)|([\s\t](//).*)##mg;
 
  # And trailing commas
  $got =~ s/,\s*([\]}])/$1/mg;

  my $ref = decode_json($got);
  if (!$ref) {
    die "Could not json parse $file\n";
  }
  return $ref;
}


sub validate_private_config {
 my($ref) = @_;
 die "Missing private.js: db password" unless ($ref->{db}{password});
 die "Missing private.js: db db" unless ($ref->{db}{db});
 die "Missing private.js: db username" unless ($ref->{db}{username});
 die "Missing private.js: db host" unless ($ref->{db}{host});
 die "Missing private.js: paths rrd" unless ($ref->{paths}{rrd});
 die "Missing private.js: paths png" unless ($ref->{paths}{png});
}

################################################################
# utilities                                                    #
################################################################


sub get_db_handle {
  my ($dbref) = @_;
  my  $dsn = sprintf("DBI:mysql:database=%s;host=%s",$dbref->{db},$dbref->{host});
  my  $dbh = DBI->connect($dsn, $dbref->{username}, $dbref->{password});
  die "Failed to connect to mysql" unless ($dbh);
  return $dbh;
}

my %my_mkdir;
sub my_mkdir {
 my($dir) = @_;
 return if ($my_mkdir{$dir}++);
 return if (-d $dir);
 system("mkdir","-p",$dir);
 return if (-d $dir);
 die "Unable to create $dir\: $!"; 

}



sub showOptionsHelp {
 my($left,$right,$a,$b,$key);
 my(@array);
 print "Usage: $0 [options] $usage\n";
 print "where options can be:\n";
 foreach $key (sort keys (%input)) {
    ($left,$right) = split(/[=:]/,$key);
    ($a,$b) = split(/\|/,$left);
    if ($b) {  
      $left = "-$a --$b";
    } else {
      $left = "   --$a";
    }
    $left = substr("$left" . (' 'x20),0,20);
    push(@array,"$left $input{$key}\n");
 }
 print sort @array;
}

# Erradicate PII.
sub destroy_researches_hopes_and_dreams_for_the_sake_of_the_children {
  $dbh->do(<<"EOF");
update survey set ip4="a29" where ip4 != '';  
EOF
  $dbh->do(<<"EOF");
update survey set ip6="a29" where ip6 != '';  
EOF
  $dbh->do(<<"EOF");
update survey set survey.cookie="a29" where survey.cookie != '';  
EOF
} ## end sub update_daily_summary




################################################################
# main                                                         #
################################################################

$MirrorConfig = get_config($argv{"config"},"MirrorConfig");
$PrivateConfig = get_config($argv{"private"},"PrivateConfig");
validate_private_config($PrivateConfig);
$dbh = get_db_handle($PrivateConfig->{db});

destroy_researches_hopes_and_dreams_for_the_sake_of_the_children();

