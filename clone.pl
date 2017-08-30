#!/usr/bin/perl
###############################################################################
#
# Version History
#
# 1.0.0		9/11/2014		Initial Release
# 1.1.0		8/30/2017		Update POD documentation in prep for public release
#
###############################################################################

# Initialize
use Getopt::Std;
use Config::IniFiles;
use threads;
use threads::shared;
use Switch;

# Get the arguments
getopts('c:u:p:h', \%opts);
my $username = $opts{'u'};
my $password = $opts{'p'};
my $timestamp = localtime( time );
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
$year += 1900;
$mon += 1;
my $datestamp = sprintf("%04d%02d%02d%02d%02d", $year, $mon, $mday, $hour, $min);

# Command-line checking
if ( $opts{'h'} ) {
	DoHelp( "ShowHelp" );
	exit( 0 );
}
unless( $opts{'c'} ) {
	DoHelp( "ConfigFile" );
	exit( 2 );
}
unless( ( $opts{'u'} ) && ( $opts{'p'} )) {
	DoHelp( "UserPass" );
	exit( 3 );
}

my %cfg;
my @threads;

tie %cfg, 'Config::IniFiles', ( -file => "$opts{'c'}" );

print "\nPreparing to clone all targets defined in configuration file \"$opts{'c'}\".\n\nPlease wait, this will take a while..\n\n";
foreach $current_target ( keys %cfg ) {
	my $t = threads->new( \&SpawnClone, $current_target );
    push( @threads, $t );
}

foreach ( @threads ) {
	my $current_target = $_->join;
	print "\nDone with clone of $current_target.\nLog info can be found at logs/$current_target\_$datestamp.log\n";
}

sub SpawnClone {
	my $current_target = shift;
	open( LOG, ">>", "logs/$current_target\_$datestamp.log" );
	print LOG "Process started on ", $timestamp, "\n";
	print "Starting clone of $current_target ...\n";
	$sourcevm = $cfg{$current_target}{'source'};
	$datastore = $cfg{$current_target}{'datastore'};
	$vmhost = $cfg{$current_target}{'vmhost'};
	$ipaddr = $cfg{$current_target}{'ipaddr'};
	$netmask = $cfg{$current_target}{'netmask'};
	$network = $cfg{$current_target}{'network'};
	$gateway = $cfg{$current_target}{'default_gateway'};
	$memory = $cfg{$current_target}{'memory'};
	$disksize = $cfg{$current_target}{'disksize'};
	$cpus = $cfg{$current_target}{'cpus'};
	$shares = $cfg{$current_target}{'shares'};
	$vcenter = $cfg{$current_target}{'vcenter'};
	$targetvm = $current_target;
	CreateTemplate( $targetvm, $ipaddr, $gateway, $netmask, $memory, $disksize, $cpus, $network );
	$log_cmd = "Command Run:\n./vmclone-lin.pl --customize_guest yes --customize_vm yes --filename ./xml/$targetvm\_$datestamp.xml --schema xml/vmcloneLin.xsd --server $vcenter --vmhost $vmhost --vmname $sourcevm --vmname_destination \"$targetvm\_$datestamp\" --datastore $datastore --username \"$username\" --password \"**********\" --shares $shares\n";
	print LOG $log_cmd;
	close( LOG );
	# The following needs to be all on the same line to preserve Windows' santity.  I know. It sucks.
	$output = `./vmclone-lin.pl --customize_guest yes --customize_vm yes --filename ./xml/$targetvm\_$datestamp.xml --schema ./xml/vmcloneLin.xsd --server $vcenter --vmhost $vmhost --vmname $sourcevm --vmname_destination \"$targetvm\_$datestamp\" --datastore $datastore --username \"$username\" --password \"$password\" --shares $shares`;
	open( LOG, ">>", "logs/$current_target\_$datestamp.log" );
	print LOG $output;
	close( LOG );
	return $current_target;
}

sub CreateTemplate {
	my ( $targetvm, $ipaddr, $gateway, $netmask, $memory, $disksize, $cpus, $network ) = @_;
	open( XML_SPEC, ">", "xml/$targetvm\_$datestamp.xml" );
	select( XML_SPEC );
	write;
	select( STDOUT );
	close( XML_SPEC );
	1;
}

sub DoHelp {
	my $error = shift;
	switch( $error ) {
		case "ConfigFile" { print "\nERROR: The config file to use was not specified.\n\nUSAGE:\n$0 <-c CONFIG_FILE.INI> <-u USERNAME> <-p PASSWORD> | [-h]\n\n" }
		case "UserPass"   { print "\nERROR: The user name and/or password was not specified.\n\nUSAGE:\n$0 <-c CONFIG_FILE.INI> <-u USERNAME> <-p PASSWORD> | [-h]\n\n" }
		case "ShowHelp"   { print "USAGE:\n$0 <-c CONFIG_FILE.INI> <-u USERNAME> <-p PASSWORD> | [-h]\n\n" }
		else              { print "USAGE:\n$0 <-c CONFIG_FILE.INI> <-u USERNAME> <-p PASSWORD> | [-h]\n\n" }
	}
}
	
# Formats
format XML_SPEC =
<?xml version="1.0"?>
<Specification>
   <Customization-Spec>
          <Domain>ihtech.com</Domain>
          <IP>@*</IP>
		      $ipaddr
          <Gateway>@*</Gateway>
		           $gateway
          <Netmask>@*</Netmask>
		           $netmask
   </Customization-Spec>
 <Virtual-Machine-Spec>
      <Memory>@*</Memory>
	          $memory
      <Disksize>@*</Disksize>
	            $disksize
      <Number-of-CPUS>@*</Number-of-CPUS>
	                  $cpus
      <Network>@*</Network>
	           $network
  </Virtual-Machine-Spec>
</Specification>
.
	

print "\nAll clones complete.\n";
__END__

=pod

=head1 mass_clone.pl - script to clone multiple VMs at once.

=head2 EXAMPLE:

=begin text

	clone.pl -c CONFIGURATION_FILE -u DOMAIN\\USERNAME -p PASSWORD
	clone.pl -h

=end text

=head2 CONFIGURATION FILE FORMAT:

=begin text

	[CLONE_TEST_TARGET]
	source=CLONE_TEST
	datastore=DS1
	vmhost=vmhost1.mycompany.com
	network=NET-10.32.2.0_23-DEV-SRVR
	netmask=255.255.255.0
	default_gateway=10.32.2.1
	ipaddr=10.10.10.11
	memory=1024
	disksize=10240
	cpus=1

	[CLONE_TEST_TARGET2]
	source=CLONE_TEST
	datastore=DS2
	vmhost=vmhost2.mycompany.com
	network=NET-10.32.2.0_23-DEV-SRVR
	netmask=255.255.255.0
	default_gateway=10.32.2.1
	ipaddr=10.10.10.12
	memory=1024
	disksize=10240
	cpus=1

=end text

=cut
