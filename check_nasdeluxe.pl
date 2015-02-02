#!/usr/bin/perl -w
#
# check_nasdeluxe.pl
#
# modified from check_thecus.pl
# - A nagios plugin to monitor a THECUS NAS applicance, esp. N16000, esp. N16000 (2.01)
#
# tested on NASdeluxe NDL-2810R V2.04.06a
#
# Usage:
#  check_nasdeluxe.pl --user=<username> --password=<password> --host=<host>
# 
# sceleton from http://exchange.nagios.org/directory/Plugins/Hardware/Storage-Systems/SAN-and-NAS/Thecus-NAS-Health/details,
# adapted for N16000.
#
# It checks for:
#  - RAID healthiness
#  - chassis temperature
#  - CPU temperature
#  - CPU load
#  - Disk bad_block
#  - Disk recognition
#  
#  License: MIT
#  Patrick Kirsch <pkirsch@zscho.de>, 2012

use strict;
use Getopt::Long;
use LWP;
use LWP::UserAgent;
use HTTP::Cookies;
use JSON;
use Data::Dumper;

my $debug = 0;

my $ua = new LWP::UserAgent;
$ua->agent('check_nasdeluxe Nagios plugin');
$ua->cookie_jar( { } );

my $user = 'admin';
my $pass = 'admin';
my $host = '127.0.0.1';

GetOptions("user=s" => \$user, "password=s" => \$pass, "host=s" => \$host);

if ($host eq '127.0.0.1') {
	$host = shift;
}

if($host eq '127.0.0.1') {
	die "Usage: $0 [--user <username>] [--password <password>] --host <host>\n";
}

if ($host =~ /\$/) {
	$host =~ s/\$//g;
}

my $res = $ua->post(
	"http://$host/adm/login.php", 
	[ 'eplang'=>'english', 
	  'p_pass' => $pass, 
	  'p_user' => $user, 
	  'action' => 'login', 
	  'option' => 'com',  
	  'username' => $user, 
	  'pwd' => $pass 
	]);

if($res->is_error()) {
	print "CRITICAL: Thecus login failed (" . $res->status_line . ")\n";
	exit 2;
}

my $aboutRes = $ua->get("http://$host/adm/getmain.php");


if(!$aboutRes->is_success()) {
	print "CRITICAL: Could not fetch status information (" . $aboutRes->status_line . ")\n";
	exit 2;
}

if(!$aboutRes =~ m/^\<html\>/s) {
	print "UNKNOWN: Could not log in to Thecus NAS";
	exit 3;
}

my $sysStat = $ua->get("http://$host/adm/getmain.php?fun=nasstatus&update=1&262");


if(!$sysStat->is_success()) {
	print "CRITICAL: Could not fetch status information (" . $sysStat->status_line . ")\n";
	exit 2;
}

my $sysStatDetail = $ua->post(
	"http://$host/adm/setmain.php", 
	{ 'fun'    => 'setstatus', 
	  'action' => 'update', 
	  'params' => '[]'
	});
	
if(!$sysStatDetail->is_success()) {
	print "CRITICAL: Could not fetch status details (" . $sysStatDetail->status_line . ")\n";
	exit 2;
}
	
print '$sysStatDetail: ',Dumper($sysStatDetail->content()) if $debug;

my $sysStatObj = decode_json($sysStatDetail->content());

print '$sysStatObj: ',Dumper($sysStatObj) if $debug;

my $status = {};

read_values($sysStatObj,$status);

sub read_values {
  my $sysStatObj = shift;
  my $status = shift;
  
  for my $item (@$sysStatObj) {
    next unless ref($item);
    if (ref($item) =~ /ARRAY/) {
      print 'is ARRAY-ref',"\n" if $debug;
      for my $values (@$item) {
        for my $entry (@{$values->{'value'}}) {
          $status->{$entry->{'key'}} = $entry->{'value'};
        }
      }
    }
  }
}

print Dumper($status) if $debug;

# cpu_temp $sysStatObj->{'cup_temp1'}, cpu_load  $sysStatObj->{'cpu_loading'}, chassis temp  $sysStatObj->{'sys_temp'}[0]->{'temp'}

# checkVal 
# @param check_name, e.g. cpu_tmep
# @param current value, e.g. 50
# @param warning threshold, e.g. 60
# @param critical, threshold, e.g. 70;
#
# @return nothing
sub checkVal {
	my ($label,$value,$warn,$critical) = @_;
	
	$value =~ s/^\s*([\.0-9]+).*$/$1/;

	if ($value > $critical) {
		print "CRITICAL: $label | current $value > $critical\n";
		exit 2;
	}
	if ($value > $warn) {
		print "WARNING: $label | current $value > $warn\n";
		exit 1;
	}

}

checkVal('cpu_temp', $status->{'cup_temp'}, 50 , 70);
checkVal('cpu_fan', $status->{'cpu_fan'}, 2000 , 3000);
checkVal('cpu_load', $status->{'cpu_loading'}, 4 , 8);
#TODO: checkVal('mem_load', $status->{'mem_loading'}, 90, 95);
checkVal('sys_temp1', $status->{'sys_temp 1'}, 55 , 70);
checkVal('sys_temp2', $status->{'sys_temp 2'}, 55 , 70);
checkVal('sys_temp3', $status->{'sys_temp 3'}, 55 , 70);


#TODO: psu 'OK' 'psu' => 'OK'
if ($status->{'psu'} !~ m/^OK$/) {
	print "CRITICAL: psu | $status->{'psu'} \n";
	exit 2;
}


print Dumper($sysStatObj) if $debug;

if (1) {
# RAID
# #####
my $sysStatRaid = $ua->get("http://$host/adm/getmain.php?fun=raid&action=getraidlist");

if(!$sysStatRaid->is_success()) {
	print "CRITICAL: Could not fetch raid information (" . $sysStatRaid->status_line . ")\n";
	exit 2;
}

my $sysRaidObj = decode_json($sysStatRaid->content());

print '$sysRaidObj: ', Dumper( $sysRaidObj ) if $debug;

for my $raid (@{$sysRaidObj->{'raid_list'}}) {
	if ($raid->{'raid_status'} ne 'Healthy') {
		print "CRITICAL: RAID id:$raid->{'raid_id'} is not marked as HEALTHY anymore\n";
		exit 2;
	}
}

# Disks
# #####
my $sysStatDisks = $ua->get("http://$host/adm/getmain.php?fun=disks&update=1");

if(!$sysStatDisks->is_success()) {
	print "CRITICAL: Could not fetch disk information (" . $sysStatDisks->status_line . ")\n";
	exit 2;
}

my $sysDiskObj = decode_json($sysStatDisks->content());
print '$sysDiskObj: ', Dumper( $sysDiskObj ) if $debug;

for my $group (@{$sysDiskObj->{'disk_data'}}) {
  for my $tray (@{$group->{'disks'}}) {
	if (exists $tray->{'link'} && $tray->{'link'} !~ /SATA\s+3\s*Gb/) {
		print "WARNING: link rate runs with slower speed\n";
		exit 1;
	}
	if (exists $tray->{'status'} && $tray->{'status'}->{'bad'} ne '0') {
		print "CRITICAL: tray:$tray->{'tray_no'} disk $tray->{'disk_name'} has bad blocks\n";
		exit 2;
	}
  }
}

}
#
# else everything is fine
my $temp = $status->{'cup_temp'};
$temp =~ s/^\s*([\.0-9]+).*$/$1/;
print "OK: NASdeluxe running normally|cpuLoad=$status->{'cpu_loading'}, cpuTemp=$temp, PSU: $status->{'psu'}, RAID: OK\n";
exit 0;
