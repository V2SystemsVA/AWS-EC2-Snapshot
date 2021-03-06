#!/usr/bin/perl

############################
## Copyright 2019, V2 Systems, Inc.
## Author: Chris Waskowich
## Contact: c.waskowich@v2systems.com; 703.361.4606x104
##
## Purpose: Create daily snapshots of EC2 instances with attached Volumes
## Version: 1.6.9
##
############################

use lib '/root/perl5/lib/perl5';
use Date::Simple ('date', 'today');
use Net::Amazon::EC2;
use Getopt::Std;
use Data::Dumper;
use Sys::Hostname;

my $gScriptVersion = "1.6.9";



############################
##
## Function: countSnapshots
## Desc: Count the AWS/EC2 snapshots to be removed
##
## First, search for snapshots that we made by this script. Then, look for
## snapshots older than "retention_days".  If both restrictions are met, then
## count the snapshot.
##
sub countSnapshots {
	my $snapshots		       = $ec2->describe_snapshots(Owner=>"self");
	my $snapshotsNum		   = scalar @$snapshots;
	my $volumes	   	           = $ec2->describe_volumes;
	my $volumesNum             = scalar @$volumes;
	my $snapshotsToMake        = 0;
	my $snapshotsToKeep	       = 0;
	my $snapshotsFromRetention = 0;
	my $snapshotStatus         = "";
	
	## Count number of volumes to snapshot, i.e., the number of snapshots to make.
	foreach my $volume (@$volumes) {
		
		my $volumeId = $volume->volume_id;

		if( defined($volume->attachments) ) {
			$instanceId    = $volume->attachments->[0]->{instance_id};
			$instanceState = $ec2->describe_instances(InstanceId=>$instanceId)->[0]->{instances_set}->[0]->instance_state->code;
			
			push(@{$instances{$instanceId}}, $volumeId);
			if($instanceState==16) {
				push(@{$instancesActive{$instanceId}}, $volumeId);
			}
			
			if( ( !$gDoActive && (
				!$gDoSpecific || 
				( $gDoSpecific && $gInstanceToSnap{$instanceId} )
			) ) || 
			( ( $gDoActive && $instanceState==16 ) && (
				!$gDoSpecific || 
				( $gDoSpecific && $gInstanceToSnap{$instanceId} )
			) ) ) {
				$snapshotsToMake++;
			}
		}
	}
	
	## Count number of "Backup" snapshots. This is prior to making snapshots and prior to 
	## pruning, so, this isn't perfect.  This basically tells us if we had a problem
	## yesterday.
	foreach my $snapshot (@$snapshots) {
		if( ($snapshot->{description}) && ($snapshot->{description} =~ m/DailyBackup--.*/) ) {
			$snapshotsToKeep++;
		}
	}
	
	$snapshotsFromRetention = $snapshotsToMake * ($gRetentionDays + 1);
	
	if($snapshotsToKeep < $snapshotsFromRetention) {
		$snapshotStatus = "ERROR - Number of snapshots to keep is less than the number of expected snapshots.";
	} else {
		$snapshotStatus = "SUCCESS - Number of snapshots to keep is the same or greater than the number of expected snapshots.";
	}
	
	
	print "Snapshot Count Summary:\n";
	print "\tExpected Snapshots to Make: " . $snapshotsToMake . "\n";
	print "\tExpected Snapshot Retention: " . $snapshotsFromRetention . "\n";
	print "\tFound Snapshot Retention: " . $snapshotsToKeep . "\n";
	print "\tStatus: " . $snapshotStatus . "\n";
}



############################
##
## Function: createSnapshots
## Desc: Create the AWS/EC2 snapshots
##
## Find the volumes, see if they are attached volumes, then snapshot the volumes.
## Optionally, if the 'a' option is specified, only get running instances
##
sub createSnapshots {
	my $deviceId;
	my %instances;
	my %instancesActive;
	my $instanceId;
	my $instanceNum;
	my $instanceName;
	my $instanceState;
	my $snapshotsMade     = 0;
	my $volumesAttchNum   = 0;
	my $instanceActiveNum = 0;
	my $volumes	   	      = $ec2->describe_volumes;
	my $volumesNum        = scalar @$volumes;
	
	print "\n\nStarting: Create Snapshots\n";

	foreach my $volume (@$volumes) {
		
		my $volumeId = $volume->volume_id;

		if( defined($volume->attachments) ) {
			$volumesAttchNum++;
			$deviceId	   = $volume->attachments->[0]->{device};
			$instanceId    = $volume->attachments->[0]->{instance_id};
			$instanceName  = $ec2->describe_instances(InstanceId=>$instanceId)->[0]->{instances_set}->[0]->name;
			$instanceState = $ec2->describe_instances(InstanceId=>$instanceId)->[0]->{instances_set}->[0]->instance_state->code;
			
			push(@{$instances{$instanceId}}, $volumeId);
			if($instanceState==16) {
				push(@{$instancesActive{$instanceId}}, $volumeId);
			}
			
			if( ( !$gDoActive && (
				!$gDoSpecific || 
				( $gDoSpecific && $gInstanceToSnap{$instanceId} )
			) ) || 
			( ( $gDoActive && $instanceState==16 ) && (
				!$gDoSpecific || 
				( $gDoSpecific && $gInstanceToSnap{$instanceId} )
			) ) ) {
				$snapshotsMade++;
				
				my $snap_description =  "DailyBackup--" . $instanceName . "--" . $instanceId . "--" . $volumeId . "--" . $deviceId;
				print "\tCreating snapshot of Volume:" . $volumeId . "(" . $deviceId . "); From Instance:" . $instanceId . "(" . $instanceName . ")\n";
		
				if(!$gDoDryRun) {
					$snapshotObject = $ec2->create_snapshot(VolumeId=>$volumeId, Description=>$snap_description);
					sleep 1;
					
					if($snapshotTags) {
						my %tags = split(/\:/, $snapshotTags);
						my $tagsref = \%tags;
						
						$snapshotId = $snapshotObject->snapshot_id;
						
						$ec2->create_tags(ResourceId=>$snapshotId, Tags=>$tagsref);
					}
				}
			}
		}
	}
	
	$instanceNum       = keys %instances;
	$instanceActiveNum = keys %instancesActive;
	
	print "\nCreate Summary:\n";
	print "\tFound Total Volumes: " . $volumesNum . "\n";
	print "\tFound Total Instances: " . $instanceNum . "\n";
	print "\tFound Attached Volumes: " . $volumesAttchNum . "\n";
	print "\tFound Active Instances: " . $instanceActiveNum . "\n";
	print "\tSnapshots Created: " . $snapshotsMade . "\n";
}



############################
##
## Function: removeSnapshots
## Desc: Remove the AWS/EC2 snapshots
##
## First, search for snapshots that we made by this script. Then, look for
## snapshots older than "retention_days".  If both restrictions are met, then
## remove the snapshot.
##
sub removeSnapshots {
	my $snapshots		    = $ec2->describe_snapshots(Owner=>"self");
	my $snapshotsNum		= scalar @$snapshots;
	my $snapshotsFromBackup = 0;
	my $snapshotsNotBackup  = 0;
	my $snapshotsToKeep	    = 0;
	my $snapshotsToRemove   = 0;
	
	print "\n\nStarting: Remove Snapshots\n";

	foreach my $snapshot (@$snapshots) {
	
		if( ($snapshot->{description}) && ($snapshot->{description} =~ m/DailyBackup--.*/) ) {
			$snapshotsFromBackup++;
			my @snapshotDateTime = split(/T/, $snapshot->{start_time});
			
			if ( $snapshotDateTime[0] < $gDeltaDate ) {
				$snapshotsToRemove++;
				print "\tRemoving: Snapshot:" . $snapshot->{snapshot_id} . "; Description: " . $snapshot->{description} . "; Dated: " . $snapshot->{start_time} . "\n";
				if(!$gDoDryRun) {
					$ec2->delete_snapshot(SnapshotId=>$snapshot->{snapshot_id});
					sleep 1;
				}
				
			} else {
				$snapshotsToKeep++;
				print "\tKeeping: Snapshot:" . $snapshot->{snapshot_id} . "; Description: " . $snapshot->{description} . "; Dated: " . $snapshot->{start_time} . "\n";
			}
		} else {
			$snapshotsNotBackup++;
		}
		
	}
	
	print "\nRemove Summary:\n";
	print "\tFound Backup Snapshots: " . $snapshotsFromBackup . "\n";
	print "\tFound Non-Backup Snapshots: " . $snapshotsNotBackup . "\n";
	print "\tSnapshots Kept: " . $snapshotsToKeep . "\n";
	print "\tSnapshots Removed: " . $snapshotsToRemove . "\n";
}



############################
##
## Start Main Code
##

my %options;
my $today         = today();
my $scriptRunTime = scalar localtime time();

getopts('dr:at:u:p:n:ig:', \%options);

## Debug Mode
$gDoDryRun = $options{'d'};
if($gDoDryRun) {
	print "\n\n########## Debug ##########\n\n\n\n";
}

## Set retention days
if($options{'r'}) {
	$gRetentionDays = $options{'r'};
} else {
	$gRetentionDays = 7;
}
$gDeltaDate = $today - $gRetentionDays;

## Get AWS Tags to assign to snapshot
if($options{'g'}) {
	$snapshotTags = $options{'g'};
}

## Get AWS Account info from Command line, if not enough information is provided, try 
## through the IAM role.

$gAWSAccount  = $options{'t'};
$gAWSUsername = $options{'u'};
$gAWSSecret   = $options{'p'};
$gAWSRegion   = $options{'n'};

if($gAWSUsername eq '' or $gAWSSecret eq '') {
	$gDoIAMRole = 1;
	$ec2 = Net::Amazon::EC2->new(
		region => $gAWSRegion
	);
	
} else {
	$gDoIAMRole = 0;
	$ec2 = Net::Amazon::EC2->new(
		AWSAccessKeyId => $gAWSUsername,
		SecretAccessKey => $gAWSSecret,
		region => $gAWSRegion
	);
	
}

if($gDoDryRun) {
	print "gAWSAccount   = $gAWSAccount\n";
	print "gAWSUsername  = " . $ec2->AWSAccessKeyId . "\n";
	print "gAWSSecret    = " . $ec2->SecretAccessKey . "\n";
	print "gAWSRegion    = " . $ec2->region . "\n\n";
}

## Check to see if only running (active) instances are to be snap shotted
$gDoActive = $options{'a'};

## Check to see if we are only doing specific instances
if($options{'i'}) {
	$gDoSpecific = 1;
	foreach (@ARGV) {
		push(@{$gInstanceToSnap{$_}}, 1);
		$listInstances .= $_ . " ";
		$gInstanceToSnapNum++;
	}
}

print "System Configuration Summary:\n";
print "\tSnapshot Host: " . hostname . "\n";
print "\tAccount: $gAWSAccount\n";
print "\tScript Version: " . $gScriptVersion . "\n";
print "\tIAM Role: " . ($gDoIAMRole ? 'Yes' : 'No') . "\n";
print "\tOnly active instances: " . ($gDoActive ? 'Yes' : 'No') . "\n";
print "\tSpecific instances (" . $gInstanceToSnapNum . "): " . $listInstances . "\n";
print "\tScript Run Time: " . $scriptRunTime . "\n";
print "\tRetention Period: " . $gRetentionDays . "\n";
print "\tRemove snapshots prior to: " . $gDeltaDate . "\n";
print "\tAssign Tags: " . $snapshotTags . "\n\n";

&countSnapshots;

&createSnapshots;

&removeSnapshots;
