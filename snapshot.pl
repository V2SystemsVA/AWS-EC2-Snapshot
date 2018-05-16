#!/usr/bin/perl

############################
## Copyright 2018, V2 Systems, Inc.
## Author: Chris Waskowich
## Contact: c.waskowich@v2systems.com; 703.361.4606x104
##
## Purpose: Create daily snapshots of EC2 instances with attached Volumes
## Version: 1.6.5
##
############################

use lib '/root/perl5/lib/perl5';
use Date::Simple ('date', 'today');
use Net::Amazon::EC2;
use Getopt::Std;
use Data::Dumper;


############################
##
## Specify the AWS/IAM Account keys.  This should probably be done through IAM roles instead.
## If the Instance that this runs from has a IAM role that allows for access to the Keys,
## then do not manually specify the keys here.
##
## These variables can also be specified in the CLI for bulk processing of various account.
## Also, need the AWS EC2 Region, options are (there are more):
##     us-east-1, us-west-1, us-west-2, us-gov-west-1
##
#$gAWSAccount = 'AWS Account Name';
#my $ec2 = Net::Amazon::EC2->new(
#        AWSAccessKeyId => '',
#        SecretAccessKey => '',
#        region => 'us-east-1'
#);


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
	
	## Count number of volumes to snapshot
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
	
	## Count number of snapshots remaining, after pruning
	foreach my $snapshot (@$snapshots) {
	
		if( ($snapshot->{description}) && ($snapshot->{description} =~ m/DailyBackup--.*/) ) {
			my @snapshotDateTime = split(/T/, $snapshot->{start_time});
			
			if ( !($snapshotDateTime[0] < $gDeltaDate) ) {
				$snapshotsToKeep++;
			}
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
my $today   = today();

getopts('dr:at:u:p:n:ig:', \%options);

## Debug Mode
$gDoDryRun = $options{'d'};

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

## Get AWS Account info from Command line, only if not already defined
if( !(defined $ec2) ) {
	$gAWSAccount  = $options{'t'};
	$gAWSUsername = $options{'u'};
	$gAWSSecret   = $options{'p'};
	$gAWSRegion   = $options{'n'};

	$ec2 = Net::Amazon::EC2->new();
	
	if($gAWSUsername eq '') {
		$gAWSUsername = $ec2->AWSAccessKeyId;
	} else {
		$ec2->AWSAccessKeyId => "$gAWSUsername";
	}
	
	if($gAWSSecret eq '') {
		$gAWSSecret = $ec2->SecretAccessKey;
	} else {
		$ec2->SecretAccessKey => "$gAWSSecret";
	}
	
	if($gAWSRegion eq '') {
		$gAWSUsername = $ec2->region;
	} else {
		$ec2->region => "$gAWSRegion";
	}
	
	if($gDoDryRun) {
		print "\ngAWSAccount = $gAWSAccount\n";
		print "gAWSUsername  = $gAWSUsername\n";
		print "gAWSSecret    = $gAWSSecret\n";
		print "gAWSRegion    = $gAWSRegion\n\n";
	}

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

if($gDoDryRun) {
	print "\n\n########## Debug ##########\n\n\n";
}
print "Account: $gAWSAccount\n\n";
print "System Configuration Summary:\n";
print "\tOnly active instances: " . ($gDoActive ? 'Yes' : 'No') . "\n";
print "\tSpecific instances (" . $gInstanceToSnapNum . "): " . $listInstances . "\n";
print "\tToday is: " . $today . "\n";
print "\tRetention Period: " . $gRetentionDays . "\n";
print "\tRemove snapshots prior to: " . $gDeltaDate . "\n";
print "\tAssign Tags: " . $snapshotTags . "\n\n";

&countSnapshots;

&createSnapshots;

&removeSnapshots;


