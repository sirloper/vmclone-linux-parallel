#!/usr/bin/perl -w
# 
# vmclone.pl modified by www.lincvz.info
# Version 1.0

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../";

use VMware::VIRuntime;
use XML::LibXML;
use AppUtil::VMUtil;
use AppUtil::HostUtil;
use AppUtil::XMLInputUtil;

$Util::script_version = "1.0";

sub check_missing_value;

my %opts = (
   vmhost => {
      type => "=s",
      help => "The name of the host",
      required => 1,
   },
   vmname => {
      type => "=s",
      help => "The name of the Virtual Machine",
      required => 1,
   },
   vmname_destination => {
      type => "=s",
      help => "The name of the target virtual machine",
      required => 1,
   },
   filename => {
      type => "=s",
      help => "The name of the configuration specification file",
      required => 0,
      default => "../sampledata/vmclone.xml",
   },
   customize_guest => {
      type => "=s",
      help => "Flag to specify whether or not to customize guest: yes,no",
      required => 0,
      default => 'no',
   },
   customize_vm => {
      type => "=s",
      help => "Flag to specify whether or not to customize virtual machine: "
            . "yes,no",
      required => 0,
      default => 'no',
   },
   schema => {
      type => "=s",
      help => "The name of the schema file",
      required => 0,
      default => "../schema/vmclone.xsd",
   },
   datastore => {
      type => "=s",
      help => "Name of the Datastore",
      required => 0,
   },
	shares => {
		      type      => "=i",
		      help       => "CPU and Memory share level assigned to new virtual machine",
		      variable => "shares",
		      required   => 1
	},
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate(\&validate);

my $memres = Opts::get_option ('memres');
my $memlimit = Opts::get_option ('memlimit');
my $cpures = Opts::get_option ('cpures');
my $cpulimit = Opts::get_option ('cpulimit');
my $shares = Opts::get_option ('shares');

Util::connect();

clone_vm();

Util::disconnect();

# Clone vm operation
# Gets destination host, compute resource views, and
# datastore info for creating the configuration
# specification to help create a clone of an existing
# virtual machine.
# ====================================================
sub clone_vm {
   my $vm_name = Opts::get_option('vmname');
   my $vm_views = Vim::find_entity_views(view_type => 'VirtualMachine',
                                        filter => {'name' =>$vm_name});
   if(@$vm_views) {
      foreach (@$vm_views) {
         my $host_name =  Opts::get_option('vmhost');
         my $host_view = Vim::find_entity_view(view_type => 'HostSystem',
                                         filter => {'name' => $host_name});

         if (!$host_view) {
            Util::trace(0, "Host '$host_name' not found\n");
            return;
         }
         # bug 449530
         my $disk_size = get_disksize();
         if($disk_size eq -1 || $disk_size eq "") {
            $disk_size = 0;
            my $devices = $_->config->hardware->device;
            foreach my $device (@$devices) {
               if (ref $device eq "VirtualDisk") {
                  $disk_size = $disk_size + $device->capacityInKB;
               }
            }
         }
         my $network_dev_key;
         my $devices = $_->config->hardware->device;
         foreach my $device (@$devices) {
            if (ref $device eq "VirtualE1000") {
               $network_dev_key = $device->key;
               last;
            }
         }
         if ($host_view) {
            my $comp_res_view = Vim::get_view(mo_ref => $host_view->parent);
            my $ds_name = Opts::get_option('datastore');
            my %ds_info = HostUtils::get_datastore(host_view => $host_view,
                                     datastore => $ds_name,
                                     disksize => $disk_size);
            if ($ds_info{mor} eq 0) {
               if ($ds_info{name} eq 'datastore_error') {
                  Util::trace(0, "\nDatastore $ds_name not available.\n");
                  return;
               }
               if ($ds_info{name} eq 'disksize_error') {
                  Util::trace(0, "\nThe free space available is less than the"
                               . " specified disksize or the host"
                               . " is not accessible.\n");
                  return;
               }
            }

            my $relocate_spec =
            VirtualMachineRelocateSpec->new(datastore => $ds_info{mor},
                                          host => $host_view,
                                          pool => $comp_res_view->resourcePool);
            my $clone_name = Opts::get_option('vmname_destination');
            my $clone_spec ;
            my $config_spec;
            my $customization_spec;

            if ((Opts::get_option('customize_vm') eq "yes")
                && (Opts::get_option('customize_guest') ne "yes")) {
               $config_spec = get_config_spec('network_dev_key' => $network_dev_key);
               $clone_spec = VirtualMachineCloneSpec->new(powerOn => 1,template => 0,
                                                       location => $relocate_spec,
                                                       config => $config_spec,
                                                       );
            }
            elsif ((Opts::get_option('customize_guest') eq "yes")
                && (Opts::get_option('customize_vm') ne "yes")) {
               $customization_spec = get_customization_lin_spec
                                              (Opts::get_option('filename'));
               $clone_spec = VirtualMachineCloneSpec->new(
                                                   powerOn => 1,
                                                   template => 0,
                                                   location => $relocate_spec,
                                                   customization => $customization_spec,
                                                   );
            }
            elsif ((Opts::get_option('customize_guest') eq "yes")
                && (Opts::get_option('customize_vm') eq "yes")) {
               $customization_spec = get_customization_lin_spec
                                              (Opts::get_option('filename'));
               $config_spec = get_config_spec('network_dev_key' => $network_dev_key);
               $clone_spec = VirtualMachineCloneSpec->new(
                                                   powerOn => 1,
                                                   template => 0,
                                                   location => $relocate_spec,
                                                   customization => $customization_spec,
                                                   config => $config_spec,
                                                   );
            }
            else {
               $clone_spec = VirtualMachineCloneSpec->new(
                                                   powerOn => 1,
                                                   template => 0,
                                                   location => $relocate_spec,
                                                   );
            }
            Util::trace (0, "\nCloning virtual machine '" . $vm_name . "' ...\n");

            eval {
               $_->CloneVM(folder => $_->parent,
                              name => Opts::get_option('vmname_destination'),
                              spec => $clone_spec);
               Util::trace (0, "\nClone '$clone_name' of virtual machine"
                             . " '$vm_name' successfully created.");
            };

            if ($@) {
               if (ref($@) eq 'SoapFault') {
                  if (ref($@->detail) eq 'FileFault') {
                     Util::trace(0, "\nFailed to access the virtual "
                                    ." machine files\n");
                  }
                  elsif (ref($@->detail) eq 'InvalidState') {
                     Util::trace(0,"The operation is not allowed "
                                   ."in the current state.\n");
                  }
                  elsif (ref($@->detail) eq 'NotSupported') {
                     Util::trace(0," Operation is not supported by the "
                                   ."current agent \n");
                  }
                  elsif (ref($@->detail) eq 'VmConfigFault') {
                     Util::trace(0,
                     "Virtual machine is not compatible with the destination host.\n");
                  }
                  elsif (ref($@->detail) eq 'InvalidPowerState') {
                     Util::trace(0,
                     "The attempted operation cannot be performed "
                     ."in the current state.\n");
                  }
                  elsif (ref($@->detail) eq 'DuplicateName') {
                     Util::trace(0,
                     "The name '$clone_name' already exists\n");
                  }
                  elsif (ref($@->detail) eq 'NoDisksToCustomize') {
                     Util::trace(0, "\nThe virtual machine has no virtual disks that"
                                  . " are suitable for customization or no guest"
                                  . " is present on given virtual machine" . "\n");
                  }
                  elsif (ref($@->detail) eq 'HostNotConnected') {
                     Util::trace(0, "\nUnable to communicate with the remote host, "
                                    ."since it is disconnected" . "\n");
                  }
                  elsif (ref($@->detail) eq 'UncustomizableGuest') {
                     Util::trace(0, "\nCustomization is not supported "
                                    ."for the guest operating system" . "\n");
                  }
                  else {
                     Util::trace (0, "Fault" . $@ . ""   );
                  }
               }
               else {
                  Util::trace (0, "Fault" . $@ . ""   );
               }
            }
         }
      }
   }
   else {
      Util::trace (0, "\nNo virtual machine found with name '$vm_name'\n");
   }
}

#Gets the config_spec for customizing the memory, number of cpu's
# and returns the spec
sub get_config_spec() {

   my %args = @_;
   my $network_dev_key = $args{'network_dev_key'};
   my $parser = XML::LibXML->new();
   my $tree = $parser->parse_file(Opts::get_option('filename'));
   my $root = $tree->getDocumentElement;
   my @cspec = $root->findnodes('Virtual-Machine-Spec');
   my $vmname ;
   my $vmhost  ;
   my $network;
   my $datastore;
   my $disksize = 4096;  # in KB;
   my $memory = 256;  # in MB;
   my $num_cpus = 1;
   my $nic_network;
   my $nic_poweron = 1;
   my $nic_allow_guest_control = 0;

   foreach (@cspec) {

      if ($_->findvalue('Network')) {
         $network = $_->findvalue('Network');
      }
      if ($_->findvalue('Memory')) {
         $memory = $_->findvalue('Memory');
      }
      if ($_->findvalue('Number-of-CPUS')) {
         $num_cpus = $_->findvalue('Number-of-CPUS');
      }
      $vmname = Opts::get_option('vmname_destination');
   }

   # Retrieve network object
   my $network_view = Vim::find_entity_view(
         view_type => 'Network',
         filter => { 'name' => $network },
         );

   # New object which defines network backing for a virtual Ethernet card
   my $virtual_device_backing_info = VirtualEthernetCardNetworkBackingInfo->new(
                                                                            network => $network_view,
                                                                            deviceName => $network);

   # New object which contains information about connectable virtual devices
   my $vdev_connect_info = VirtualDeviceConnectInfo->new(
                                                        startConnected => $nic_poweron,
                                                        allowGuestControl => $nic_allow_guest_control,
                                                        connected => '1');
   # New object which define virtual device
   my $network_device = VirtualE1000->new(
                                       key => $network_dev_key,
                                       backing => $virtual_device_backing_info,
                                       connectable => $vdev_connect_info);

   # New object which encapsulates change specifications for an individual virtual device
   my @device_config_spec = VirtualDeviceConfigSpec->new(
                                                     operation => VirtualDeviceConfigSpecOperation->new('edit'),
                                                     device => $network_device);

   # Define Shares and Limits - tweaked with static values for cpu + memory to test.
   my $sl = SharesLevel->new('custom');
   my $sh = SharesInfo->new(level => $sl, shares => $shares);
   my $mem_share = ResourceAllocationInfo->new(shares => $sh);
   my $cpu_share = ResourceAllocationInfo->new(shares => $sh);

   # New object which encapsulates configuration settings when creating or reconfiguring a virtual machine
   my $vm_config_spec = VirtualMachineConfigSpec->new(
                                                  name => $vmname,
                                                  memoryMB => $memory,
                                                  numCPUs => $num_cpus,
												  cpuAllocation => $cpu_share,
												  memoryAllocation => $mem_share,
                                                  deviceChange => \@device_config_spec);
   return $vm_config_spec;
}

sub get_disksize {
   my $disksize = -1;
   my $parser = XML::LibXML->new();

   eval {
      my $tree = $parser->parse_file(Opts::get_option('filename'));
      my $root = $tree->getDocumentElement;
      my @cspec = $root->findnodes('Virtual-Machine-Spec');

      foreach (@cspec) {
         $disksize = $_->findvalue('Disksize');
      }
   };
   return $disksize;
}

# check missing values of mandatory fields
sub check_missing_value {
   my $valid= 1;
   my $filename = Opts::get_option('filename');
   my $parser = XML::LibXML->new();
   my $tree = $parser->parse_file($filename);
   my $root = $tree->getDocumentElement;
   my @cust_spec = $root->findnodes('Customization-Spec');
   my $total = @cust_spec;
   if (!$cust_spec[0]->findvalue('IP')) {
      Util::trace(0,"\nERROR in '$filename':\n IP address value missing ");
      $valid = 0;
   }
   if (!$cust_spec[0]->findvalue('Netmask')) {
      Util::trace(0,"\nERROR in '$filename':\n Netmask value missing ");
      $valid = 0;
   }
   if (!$cust_spec[0]->findvalue('Gateway')) {
      Util::trace(0,"\nERROR in '$filename':\n Gateway value missing ");
      $valid = 0;
   }
   if (!$cust_spec[0]->findvalue('Domain')) {
      Util::trace(0,"\nERROR in '$filename':\n domain value missing ");
      $valid = 0;
   }
   return $valid;
}

sub validate {
   my $valid= 1;
   if ((Opts::get_option('customize_vm') eq "yes")
                || (Opts::get_option('customize_guest') eq "yes")) {

      $valid = XMLValidation::validate_format(Opts::get_option('filename'));
      if ($valid == 1) {
         $valid = XMLValidation::validate_schema(Opts::get_option('filename'),
                                             Opts::get_option('schema'));
         if ($valid == 1) {
            $valid = check_missing_value();
         }
      }
   }

    if (Opts::option_is_set('customize_vm')) {
       if ((Opts::get_option('customize_vm') ne "yes")
             && (Opts::get_option('customize_vm') ne "no")) {
          Util::trace(0,"\nMust specify 'yes' or 'no' for customize_vm option");
          $valid = 0;
       }

    }
    if (Opts::option_is_set('customize_guest')) {
       if ((Opts::get_option('customize_guest') ne "yes")
             && (Opts::get_option('customize_guest') ne "no")) {
          Util::trace(0,"\nMust specify 'yes' or 'no' for customize_guest option");
          $valid = 0;
       }
    }
   return $valid;
}

# This subroutine constructs the customization spec for virtual machines.
# Input Parameters:
# ----------------
# filename      : The location of the input XML file. This file contains the
#                 various properties for customization spec
#
# Output:
# ------
# It returns the customization spec as per the input XML file

sub get_customization_lin_spec {
   my ($filename) = @_;
   my $parser = XML::LibXML->new();
   my $tree = $parser->parse_file($filename);
   my $root = $tree->getDocumentElement;
   my @cspec = $root->findnodes('Customization-Spec');

   # Default Values
   my $ipaddr;
   my $netmask;
   my @gateway;
   my $domain;

   foreach (@cspec) {
      if ($_->findvalue('IP')) {
         $ipaddr = $_->findvalue('IP');
      }
      if ($_->findvalue('Netmask')) {
         $netmask = $_->findvalue('Netmask');
      }
      if ($_->findvalue('Gateway')) {
         $gateway[0] = $_->findvalue('Gateway');
      }
      if ($_->findvalue('Domain')) {
         $domain = $_->findvalue('Domain');
      }
   }

   # New object which is a collection of global IP settings for a virtual network adapter. In Linux, DNS server settings are global
   my $customization_global_settings = CustomizationGlobalIPSettings->new();

   # New object which define hostname with name of the virtual machine
   my $cust_name =
      CustomizationVirtualMachineName->new();

   # New object which contains machine-wide settings that identify a Linux machine
   my $cust_linprep =
      CustomizationLinuxPrep->new(
                              domain => $domain,
                              hostName => $cust_name);

   # New object which define a static IP Address for the virtual network adapter
   my $customization_fixed_ip = CustomizationFixedIp->new(ipAddress => $ipaddr);

   # New object which define IP settings for a virtual network adapter
   my $cust_ip_settings =
      CustomizationIPSettings->new(
                               gateway => \@gateway,
                               subnetMask => $netmask,
                               ip => $customization_fixed_ip);

   # New object which associate a virtual network adapter with its IP settings
   my $cust_adapter_mapping =
      CustomizationAdapterMapping->new(adapter => $cust_ip_settings);

   # New object, list of CustomizationAdapterMapping
   my @cust_adapter_mapping_list = [$cust_adapter_mapping];

   # New object which contains information required to customize a virtual machine guest OS
   my $customization_spec =
      CustomizationSpec->new(
                         identity=>$cust_linprep,
                         globalIPSettings=>$customization_global_settings,
                         nicSettingMap=>@cust_adapter_mapping_list);

   return $customization_spec;
}