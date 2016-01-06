#!/usr/bin/perl

############################
## Copyright 2016, V2 Systems, Inc.
## Author: Chris Waskowich
## Contact: c.waskowich@v2systems.com
##
## Purpose: Create daily snapshots of EC2 instances with attached Volumes
## Version: 1.0
##
############################

use Date::Simple ('date', 'today');
use Net::Amazon::EC2;
use Getopt::Std;
use Data::Dumper;


############################
##
## Specify the number of days of retention_days
##
my $retentionDays = 7;


############################
##
## Specify the AWS/IAM Account keys.  This should probably be done through IAM roles instead.
##
## V2 Systems, Inc.
##
my $ec2 = Net::Amazon::EC2->new(
        AWSAccessKeyId => '',
        SecretAccessKey => '',
        region => 'us-east-1' # Options: us-gov-west-1 | us-east-1
);


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
	
	print "Starting: Create Snapshots\n";

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
			
			if( !$gDoActive || ($gDoActive && $instanceState==16) ) {
				$snapshotsMade++;
				
				my $snap_description =  "DailyBackup--" . $instanceName . "--" . $instanceId . "--" . $volumeId . "--" . $deviceId;
				print "Creating snapshot of Volume:" . $volumeId . "(" . $deviceId . "); From Instance:" . $instanceId . "(" . $instanceName . ")\n";
		
				if(!$gDoDryRun) {
					$ec2->create_snapshot(VolumeId=>$volumeId, Description=>$snap_description);
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
	
	print "Starting: Remove Snapshots\n";

	foreach my $snapshot (@$snapshots) {
	
		if( ($snapshot->{description}) && ($snapshot->{description} =~ m/DailyBackup--.*/) ) {
			$snapshotsFromBackup++;
			my @snapshotDateTime = split(/T/, $snapshot->{start_time});
			
			if ( $snapshotDateTime[0] < $gDeltaDate ) {
				$snapshotsToRemove++;
				print "Removing: Snapshot:" . $snapshot->{snapshot_id} . "; Description: " . $snapshot->{description} . "; Dated: " . $snapshot->{start_time} . "\n";
				if(!$gDoDryRun) {
					$ec2->delete_snapshot(SnapshotId=>$snapshot->{snapshot_id});
				}
				
			} else {
				$snapshotsToKeep++;
				print "Keeping: Snapshot:" . $snapshot->{snapshot_id} . "; Description: " . $snapshot->{description} . "; Dated: " . $snapshot->{start_time} . "\n";
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

my %Options;
my $today   = today();
$gDeltaDate = $today - $retentionDays;

getopts('dr:a', \%Options);

## Debug Mode
$gDoDryRun = $Options{'d'};

## Override retention period
if($Options{'r'}) {
	$retentionDays = $Options{'r'};
}

## Check to see if only running (active) instances are to be snap shotted
$gDoActive = $Options{'a'};


if($gDoDryRun) {
	print "\n\n########## Debug ##########\n\n\n";
}
print "Starting: Daily Snapshot Retention System\n";
print "System Configuration Summary:\n";
print "\tOnly active instances: " . ($gDoActive ? 'Yes' : 'No') . "\n";
print "\tToday is: " . $today . "\n";
print "\tRetention Period: " . $retentionDays . "\n";
print "\tRemove snapshots prior to: " . $gDeltaDate . "\n\n";

&createSnapshots;

print "\n\n";

&removeSnapshots;
