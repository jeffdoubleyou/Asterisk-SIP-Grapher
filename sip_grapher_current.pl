#!/usr/bin/perl

#####################################################################################################
#
# sip_grapher
#
# This program is used to scrape Asterisk log files and build graphs displaying the SIP session for a
# given call using SIP debug messages.
#
# Search by phone number or Call-ID
#
# Version 2.6
#
# Date: 05/04/2010
#
# Author:
#
#	Jeffrey Weitz
#	jeffdoubleyou@gmail.com
#	jeffdoubleyou.com
#
#
# Changelog:
#
#	2.0 - 03/06/2010
#	
#		1. Initial re-write of sip_grapher.pl version 1.0
#
#	2.1 - 03/08/2010 
#
#		1. Fixed CANCEL transaction
#		2. Automated version check and upgrading
#		3. Help and usage fixes
#		
#	2.2 - 03/13/2010
#
#		1. Fixed issue with non phone calls ( registration, options, etc. ) were being used
#		   when searching for matching calls.
#
#		2. Fixed multiple call selection - only one graph was produced due to backwards
#		   matching of call ID vs list.
#
#		3. If there are no matching calls, it won't ask you to select a call.
#
#		4. Fixed SIP messages with / such as Call Leg/Transaction does not exist - where
#		   previously it would only show Call Leg.
#
#	2.3 - 03/19/2010
#
#		1. Added date / time in each SIP message for ease of reading
#
#	2.4 - 03/31/2010
#
#		1. Fixed certain types of SIP packets not being read ( Thanks Monica! )
#
#	2.5 - 04/06/2010
#
#		1. Now supports E.164 formatted phone numbers in packets
#
#	2.6 - 05/04/2010
#
#		1. Fixed issue with selecting log file path ( forgot to allow input )
#
#		2. Fixed log file selection numbers where there would always be two extra entries.
#
#		3. Cleaned up STDIN input for mode / call-id / number input
#
######################################################################################################

use strict;
use LWP::UserAgent;
use LWP::Simple;
use Getopt::Long;
use Data::Dumper;

# Version info
my $version = 2.6;
my $version_date = '05/04/2010';

# Disable output buffering
$|++;

# Log start and end time
my $start	= time;
my $end		= 0;

# Constants
use constant GRAPH_URL		=> 'http://www.jeffdoubleyou.com/bin/gengraph';
use constant VERSION_URL	=> 'http://www.jeffdoubleyou.com/sip_grapher_version.txt';
use constant CURRENT_URL	=> 'http://www.jeffdoubleyou.com/pub/Downloads/SIPGrapher/sip_grapher_current.pl';

# Set defaults
my $logpath	= '/var/log/asterisk/messages';
my $verbose	= undef;
my $debug	= undef;
my $priority	= undef;
my $proxy	= undef;
my $ignore_xdid	= undef;
my $chk_help	= undef;
my $chk_version	= undef;
my $upgrade_tmp = undef;
my $pid		= undef;

# Get command line options
GetOptions(
	"verbose"	=> \$verbose,
	"debug"		=> \$debug,
	"priority"	=> \$priority,
	"proxy=s"	=> \$proxy,
	"ignore-xdid"	=> \$ignore_xdid,
	"logpath=s"	=> \$logpath,
	"version"	=> \$chk_version,
	"help"		=> \$chk_help,
	"upgrade=s"	=> \$upgrade_tmp,
	"pid=s"		=> \$pid,
);

if($upgrade_tmp && $pid)
{
	kill $pid;
	
	# Make a backup or die
	unless(link $upgrade_tmp, $upgrade_tmp.time)
	{
		message({ TYPE => 'INFO', MESSAGE => "Could not make a backup $!" });
		exit;
	}
	# Remove the old versoin
	unless(unlink $upgrade_tmp)
	{
		message({ TYPE => 'INFO', MESSAGE => "Could not remove old copy ( $upgrade_tmp ) - $!" });
		exit;
	}
	unless(link $0, $upgrade_tmp)
	{
		message({ TYPE => 'INFO', MESSAGE => "Could not write new file ( $upgrade_tmp ) - $@ $!" });
		exit;
	}
	system($upgrade_tmp);
	exit;
}

if($chk_help)
{
	show_version({ VERSION => $version, DATE => $version_date });
	show_usage( );
	exit;
}
if($chk_version)
{
	show_version({ VERSION => $version, DATE => $version_date });
	exit;
}

# Write startup debug messages
message({ TYPE => 'DEBUG', DEBUG => $debug, MESSAGE => "VERBOSE: $verbose	" });
message({ TYPE => 'DEBUG', DEBUG => $debug, MESSAGE => "PRIORITY: $priority	" });
message({ TYPE => 'DEBUG', DEBUG => $debug, MESSAGE => "PROXY: $proxy	" });
message({ TYPE => 'DEBUG', DEBUG => $debug, MESSAGE => "IGNORE X-DID: $ignore_xdid	" });
message({ TYPE => 'DEBUG', DEBUG => $debug, MESSAGE => "LOGPATH: $logpath	" });

# Version check
my $current_version = get(VERSION_URL);
chomp($current_version);
if($current_version > $version)
{
	print "\n\nYour $0 version ( $version ) is out of date.  Current version $current_version is available at " . CURRENT_URL ."\n\n";
	        
	# Ask if they want to upgrade:
	my $upgrade;
	while(!$upgrade)
	{ 
		$upgrade = read_cmd("Would you like to automatically upgrade to version $current_version? [y/n]",'');
        	$upgrade =~ s/[^yn]//g;
	}
	if($upgrade eq 'y')
	{
		my $upgrade_success = upgrade_version({ DEBUG => $debug, VERBOSE => $verbose, VERSION => $version });
		if(!$upgrade_success)
		{
			message({ TYPE => 'INFO', MESSAGE => "Unable to upgrade - $@" });
		}
	}
	else
	{
		message({ TYPE => 'INFO', MESSAGE => "Not upgrading to current version" });
	}
}

# Lower priority unless priority flag is set
if($priority)
{
	message({ TYPE => 'VERBOSE', VERBOSE => $verbose, MESSAGE => 'Script set to run at high priority - not attempting to renice' });
}
else
{
	
	# Try to determine the path of renice
	my $renice;

	if(-e "/usr/bin/renice")
	{
		$renice = '/usr/bin/renice';
	}		
	elsif(-e "/usr/bin/which")
	{
		$renice = `/usr/bin/which renice`;
	}
	else
	{
		message({ MESSAGE => "Unable to lower script priority - renice not found" });
	}

	# Renice the current process
	if($renice)
	{
		system($renice, '+15', $$) == 0 || message({ MESSAGE => "Unable to lower script priority - renice exited with $?" });
	}

}

# Choose a log file:
my $logfile = choose_log({ DEBUG => $debug, VERBOSE => $verbose, LOGPATH => $logpath }) || die ("Log file was not chosen [ $@ ]\n");

# Get mode:
my $mode = get_mode();

my $callid;
my $number;

if($mode == 1)
{
	# Get the call ID:
	$callid = get_call_id({ DEBUG => $debug, VERBOSE => $verbose, LOG => $logfile });
}
else
{
	$number = get_number( );
}

# Grab the time before the log is read:
$start = time;

# Read the log and put the hash into $sip:
my $sip = read_log({ DEBUG => $debug, VERBOSE => $verbose, LOG => $logfile, CALLID => $callid, NUMBER => $number, IGNOREXDID => $ignore_xdid }) || die("Unable to read log [ $@ ]\n");

# Grab the time now that the log has finally been scoured:
$end = time;

# Calculate the length of time that it took to read the file:
my $duration = ( $end - $start );
message({ VERBOSE => $verbose, TYPE => 'VERBOSE', MESSAGE => "Took $duration seconds to read the log file" });

# Build the graph!
message({ DEBUG => $debug, TYPE => 'DEBUG', MESSAGE => Dumper( $sip )});

# Get a list of desired calls to graph ( if necessary )
if( keys %$sip )
{
	my $list = select_calls({ SIP => $sip });
	message({ VERBOSE => $verbose, TYPE => 'VERBOSE', MESSAGE => "Using this list of call ids: $list" });
	my @msc = build_graph({ SIP => $sip, LIST => $list });

	# Create a user agent object
	my $ua = LWP::UserAgent->new;

	foreach(@msc)
	{
		# Create a request
		my $req = HTTP::Request->new(POST => GRAPH_URL);
		$req->content($_);
	
		# Pass request to the user agent and get a response back
		my $res = $ua->request($req);

	 	# Check the outcome of the response
		if ($res->is_success) {
			print "GRAPH URL: " . $res->content . "\n";
		}
		else
		{
			print "ERROR: " . $res->status_line, "\n";
		}
		print "\n";
	}
}
else
{
	print "\nNo matching calls were found\n\n";
}

# Get Call ID
sub get_call_id 
{
	my $id;

	while(!$id)
	{
		$id = read_cmd("Enter the Call-ID",'');
		$id =~ s/[^a-zA-Z0-9\-\_]//g;
	}
	return $id;
}

sub get_mode
{
	my $mode;
	while(!$mode)
	{
		$mode = read_cmd("Search by phone number or call ID?\n\t1. Call ID\n\t2. Phone Number\n\nEnter Selection",'');
		$mode =~ s/[^a-zA-Z0-9\-\_]//g;
	}
	return $mode;
}

sub get_number
{
	my $number;
	while(!$number)
	{
		$number = read_cmd("Enter all or part of the number",'');
		$number =~ s/[^a-zA-Z0-9\-\_]//g;
	}
	return $number;
}

# Choose the log file that the call is in:
sub choose_log
{
	# Get passed arguments ( hashref )
	my $params = shift || {};

	# Must have log path defined
	unless($params->{LOGPATH})
	{
		$@ = "Log path was undefined";
		return undef;
	}

	# Initialize these vars;
	my($logdir, $filename);

	# If the logpath is good, continue...otherwise, return.
	# Format needs to be /path/to/file/filename - like /var/log/asterisk/messages where messages is the log file
	if($params->{LOGPATH} =~ m/^(.*\/)(\S+)/)
	{
		$logdir		= $1;
		$filename	= $2;		
	}
	else
	{
		$@ = "Bad log path - " . $params->{LOGPATH};
		return undef;
	}

	# Unless the directory and log file path is set:
	unless($logdir && $filename)
	{
		# Honestly, this should never happen...so, i'm not worried:
		$@ = "Somehow, we failed to set a logdirectory and path - please submit a bug report to jeffdoubleyou\@gmail.com";
		return;		
	}

	# Some verbose logging
	message({ TYPE => 'VERBOSE', VERBOSE => $params->{VERBOSE}, MESSAGE => "Looking at files in $logdir matching $filename" });


	#open log directory and push file info into the @files array:
	my(@files);

	unless(opendir(DIR, $logdir))
	{
		$@ = "Unable to open log directory - $logdir [ $! ]";
		return undef;
	}

	# Init the file selection counter:
	my $file_cnt = 0;

	# read the directory and look for files matching our log file path:
	while(my $file_list = readdir(DIR))  {
		# Only continue if the filename matches:
		next unless $file_list =~ /$filename/;

		# Increase the selection counter:
		$file_cnt++;	

		#get file stat and add the file date to the array. we'll split by pipe | later on:
		my(@file_stat) = stat($logdir . '/' . $file_list);
		$files[$file_cnt] = $file_stat[9] . '|' . $logdir . $file_list;
	}
	
	#Sort log file array:
	@files = sort { $b cmp $a } @files;

	#Ask user to select the file to use for parsing:
	print "Please choose which log file to use:\n\n";

	#Reset file count and print our list of files:
	$file_cnt = 0;
	foreach(@files)  {
		my($date, $filename) = split(/\|/, $_);
		if(defined $filename)
		{
			print "\t$file_cnt. [ " . localtime($date) . " ] $filename\n";
			$file_cnt++;
		}
	}

	#Read selection from console:
	my $log_select = &read_cmd("\n\tEnter selection (0 to " . ($file_cnt - 1) . ")", '0');

	#Clean up user entry and define the log file:
	$log_select =~ s/\D//g;
	$log_select = 0 unless $log_select =~ /^\d+$/;
	my $log_file = $files[$log_select];
	
	#Strip off the leading file data before the pipe:
	$log_file =~ s/^.*\|//;
	
	#Return selected log file:
	return $log_file;
}	

# Show message
# 
# Send message to console based on log level
#
# Args:
#	Hash array { DEBUG => 1, VERBOSE => 1, TYPE => 'INFO', MESSAGE => 'This is information!'  }
#
# If TYPE are not defined, the message type will automatically be considered to be informational.
sub message
{

	# Get params
	my $params = shift || {};
	
	if(!$params->{TYPE} || $params->{TYPE} eq 'INFO')
	{
		print '[ INFO ] ' . $params->{MESSAGE} . "\n";
		return;
	}

	if((!$params->{DEBUG} && !$params->{VERBOSE}) || ( $params->{TYPE} ne 'VERBOSE' && $params->{TYPE} ne 'DEBUG' ))
	{
		return;
	}

	if($params->{$params->{TYPE}})
	{
		print '[ ' . $params->{TYPE} . ' ] ' . $params->{MESSAGE} . "\n";
	}

}

# Read command
sub read_cmd {
	my($prompt,$default_value) = @_;

	if ($default_value) {
		print $prompt, "[", $default_value, "]: ";
	} 
	else {
		print $prompt, ": ";
	}

	$| = 1;
	$_ = <STDIN>;
	$_ =~ s/\cC//g;
	$_ =~ s/\r//g;

	chomp;

	$_ = $default_value unless $_ ne "";
	return $_;
}

# Let the user select call IDs:
sub select_calls
{
	my $params = shift || {};

	unless($params->{SIP})
	{
		$@ = "NO SIP Data provided";
		return undef;
	}

	# Store call IDs:
	my @calls = ();
	my $cnt = 0;
	
	# Print a header
	print "Found the following calls from the number that you provided:\n\n";

	foreach my $key ( keys %{$params->{SIP}} )
	{
		push(@calls, $key);
		my $start	= $params->{SIP}->{$key}->{PACKETS}[0]->{DATETIME};
		my $end		= $params->{SIP}->{$key}->{PACKETS}[-0]->{DATETIME};
		my $to		= $params->{SIP}->{$key}->{TO};
		my $from	= $params->{SIP}->{$key}->{CIDNUM};

format =
@<<)	@<<<<<<<<<<<<<<<<<<<< TO: @<<<<<<<<<<<<<<< FROM: @<<<<<<<<<<<<<<< CALL ID: @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$cnt	$start			  $to			 $from			   $key
.
write;

		# Increment our counter
		$cnt++;
	}	

	my $ids = read_cmd("Select one or more calls separated by space or comma",'');
        $ids =~ s/[^0-9, ]//g;
	
	my $list = '';
	foreach(split(/\D+/, $ids))
	{
		if($calls[$_])
		{
			$list .= $calls[$_] . '|';
		}
	}

	return $list;

}
# Build graph from hash
sub build_graph
{
	my $params = shift || {};

	unless( $params->{SIP} )
	{
		$@ = "NO SIP Data provided";
		return undef;
	}

	# Store graphs here:
	my @graphs = ();

	foreach my $key ( keys %{$params->{SIP}} )
	{
		# If a list was defined and this call id isn't in the list, then skip it
		if(defined $params->{LIST} && $params->{LIST} !~ /$key/)
		{
			next;
		}

		# This basic call info will go into the box at the top of the graph:
		my $info	 =  ' ---- CALL DATA ---- \n';
		$info		.= 'To: ' . $params->{SIP}->{$key}->{TONAME} . ' ' . $params->{SIP}->{$key}->{TO} . '\n';
		$info		.= 'Hardware: ' . $params->{SIP}->{$key}->{DESTAGENT} . '\n\n';
		$info		.= 'FROM: ' . $params->{SIP}->{$key}->{CIDNAME} . ' ' . $params->{SIP}->{$key}->{CIDNUM} . '\n';
		$info		.= 'Hardware: ' . $params->{SIP}->{$key}->{SOURCEAGENT};
	
		# Start setting up the graph data
		my $msc;
		$msc		 = 'msc {' . "\n";
		$msc		.= 'width = "650";' . "\n";
		$msc		.= "PBX,EXTERNAL;\n";
		$msc		.= 'PBX rbox EXTERNAL [ label = "' . $info . '\n"];' . "\n";
		$msc		.= '|||;' . "\n";
	
		# Cycle through each packet and add the info to the graph:
		foreach(@{$params->{SIP}->{$key}->{PACKETS}})
		{
			my $dir;
			if($_->{DIRECTION} eq 'to')
			{
				$dir = ' => ';
			}
			else
			{
				$dir = ' <= ';
			}
			$msc	.= 'PBX' . $dir . 'EXTERNAL [ label = "' . $_->{METHOD} . '\n' . $_->{DATETIME} . '"];' . "\n";
			$msc	.= '|||;' . "\n";
		}

		$msc		.= 'PBX rbox EXTERNAL [ label = "\nCall started  at : ' . ${$params->{SIP}->{$key}->{PACKETS}}[0]->{DATETIME} . '\n';
		$msc		.= 'Call complete at : ' . ${$params->{SIP}->{$key}->{PACKETS}}[-1]->{DATETIME} . '\n" ];' . "\n";
		$msc		.= '}';
	

		# Push the MSC graph data:
		push(@graphs, $msc);
	}

	return @graphs;
}

sub find_call_id
{
	my $params = shift || {};

	# Better have a log
	unless($params->{LOG})
	{
		$@ = "LOG not defined\n";
		return undef;
	}

	# Show me the number!
	unless($params->{NUM})
	{
		$@ = "NUM not defined\n";
		return undef;
	}

	# Define some necessary variables:
	my $capture = undef;
	my $date_time;
	my $callid;
	
	# Bust the log file open!
	unless(open(F,$params->{LOG}))
	{
		$@ = "Could not open the log? - $!";
		return undef;
	}

	my $tmp = {};
	my $sip = {};

	# Split sip packet key / val pairs in the header using this
	my $kv_separator = ': ';

	
}
#
#
sub read_log
{
	my $params = shift || {};

	# Um..don't make me choose this log!
	unless($params->{LOG})
	{
		$@ = "LOG not defined\n";
		return undef;
	}

	# Make sure a call ID was provided
	unless($params->{CALLID} || $params->{NUMBER})
	{
		$@ = "Call-ID must be provided\n";
		return undef;
	}

	message({ DEBUG => $params->{DEBUG}, TYPE => 'DEBUG', MESSAGE => "CALL ID: " . $params->{CALLID} });
	message({ DEBUG => $params->{DEBUG}, TYPE => 'DEBUG', NUMBER => "CALL ID: " . $params->{NUMBER} });
	
	# Define some necessary variables:
	my $capture = undef;
	my $date_time;
	my $callid;

	# Bust the file open
	unless(open(F,$params->{LOG}))
	{
		$@ = "Unable to open log $!";
		return undef;
	}

	# Setup our temporary hash for storing raw SIP packet data before confirming that it's good
	# Then we throw the confirmed packet data into $sip
	my $tmp = {};
	my $sip = {};
	
	# This is what each key / value in the SIP packet will be separated by:
	my $kv_separator = ':';


# ------------------ FOR EXAMPLE -----------------------------------#
#INVITE sip:333-3333@vegspace.com SIP/2.0
#Via: SIP/2.0/UDP 66.54.140.46:5060;branch=z9hG4bK08f32d23;rport
#From: "LSAN DA 01 CA" <sip:2132684579@66.54.140.46>;tag=as6801cfc9
#To: <sip:333-3333@vegspace.com>
#Contact: <sip:2132684579@66.54.140.46>
#Call-ID: 0c1382a660c0bbf037212ea63f688a9c@66.54.140.46
#CSeq: 102 INVITE
#User-Agent: Asterisk PBX
#Max-Forwards: 70
#Date: Mon, 08 Mar 2010 03:18:46 GMT
#Allow: INVITE, ACK, CANCEL, OPTIONS, BYE, REFER, SUBSCRIBE, NOTIFY, INFO
#Supported: replaces
#Content-Type: application/sdp
#Content-Length: 332
# ------------------ FOR EXAMPLE -----------------------------------#


	# Iterate file
	while( <F> )
	{
		# Check to see if the capture should end ( just a new line ) then populate the SIP hash w/ the proper data
		if ($capture && $_ =~ /^\n$/)
		{
			# Stop capturing
			$capture = undef;
			
			# Clean up the call ID:
			$tmp->{'CALL-ID'} =~ s/\@.*//;
			chomp $tmp->{'CALL-ID'};
	
			# Make sure this is a call and not registration / options / etc.
			unless( $tmp->{'METHOD'} eq 'INVITE' || ( defined $sip->{$tmp->{'CALL-ID'}}->{PACKETS}[0] && $sip->{$tmp->{'CALL-ID'}}->{PACKETS}[0]->{METHOD} eq 'INVITE' ))
			{
				message({ TYPE => 'VERBOSE', VERBOSE => $params->{VERBOSE}, MESSAGE => 'Mathing packet is not a call - skipping call ID: ' . $tmp->{'CALL-ID'} });
				if(defined $sip->{$tmp->{'CALL-ID'}})
				{
					delete $sip->{$tmp->{'CALL-ID'}};
				}
				next;
			}

			message({ TYPE => 'VERBOSE', VERBOSE => $params->{VERBOSE}, MESSAGE => 'Adding packet to ' . $tmp->{'CALL-ID'} });

			# Unless the CALL-ID key is defined, we will continue:
			unless($tmp->{'CALL-ID'})
			{
				next;
			}

			# Now we start to setup our SIP hash keys:


			# Set caller ID info (example below):
			# From: "LSAN DA 01 CA" <sip:2132684579@66.54.140.46>;tag=as6801cfc9
			# To: <sip:333-3333@vegspace.com>
			if(defined $tmp->{FROM} && ( !defined $sip->{$tmp->{'CALL-ID'}}->{CIDNAME} && !defined $sip->{$tmp->{'CALL-ID'}}->{CIDNUM} ) && ( $tmp->{FROM} =~ /^\"?([a-zA-Z0-9\ \-\_\+]*)\"?\s*\<sip:([a-zA-Z0-9\-\_\+]+)/ ))
                        {
                                $sip->{$tmp->{'CALL-ID'}}->{CIDNAME}    = $1 || $2;
                                $sip->{$tmp->{'CALL-ID'}}->{CIDNUM}     = $2 || $1;
                        }

			# Define the TO field - I don't think there can be two values but we'll just be careful because I think it's valid to have a to CID type val
			if(defined $tmp->{TO} && !defined $sip->{$tmp->{'CALL-ID'}}->{TO} && $tmp->{TO} =~ /^\"?([a-zA-Z0-9\ \-\_\+]*)\"?\s*\<sip:([a-zA-Z0-9\-\_\+]+)/ )
			{
                                $sip->{$tmp->{'CALL-ID'}}->{TONAME}    = $1 || $2;
                                $sip->{$tmp->{'CALL-ID'}}->{TO}     = $2 || $1;
			}

			if(defined $tmp->{DID} && !defined($sip->{$tmp->{'CALL-ID'}}->{DID}))
			{
				$sip->{$tmp->{'CALL-ID'}}->{DID} = $tmp->{DID};
				if($tmp->{'X-DID'} && !defined $params->{IGNOREXDID})
				{
					message({ TYPE => 'VERBOSE', VERBOSE => $params->{VERBOSE}, MESSAGE => 'USING X-DID ( ' . $tmp->{'X-DID'} . ' )' });
					$sip->{$tmp->{'CALL-ID'}}->{DID} = $tmp->{'X-DID'};
				}
			}

			# Get the user agent???
			if(defined $tmp->{'USER-AGENT'} && $tmp->{METHOD} =~ /(INVITE|TRYING|PROGRESS|RINGING)/i )
			{
				if($tmp->{METHOD} eq 'INVITE')
				{
					$sip->{$tmp->{'CALL-ID'}}->{SOURCEAGENT} = $tmp->{'USER-AGENT'};
				}
				else
				{
					$sip->{$tmp->{'CALL-ID'}}->{DESTAGENT} = $tmp->{'USER-AGENT'};
				}
			}

			# OK Let's setup a new packet ( Create a new array if this is the first packet we've found) :
			$sip->{$tmp->{'CALL-ID'}}->{PACKETS}||();
			
			# OK, what do i do here......
			my @packet = ();
			my $holder = {};
			
			# FAR	= to
			# NEAR	= from
			if(defined $tmp->{FAR})
			{
				$holder->{DIRECTION} = 'to';
			}
			else
			{
				$holder->{DIRECTION} = 'from';
			}

			# Set date and time of course!
			$holder->{DATETIME} = $date_time;

			# And I guess all that's left is contact and method!
			if(defined $tmp->{CONTACT} && $tmp->{CONTACT} =~ /\<sip:\s?(\S+)?\>/)
			{
				$holder->{CONTACT} = $1;
			}

			# Set method
			$holder->{METHOD} = $tmp->{METHOD};

			# Push hasharray into hasharray!
			push(@{$sip->{$tmp->{'CALL-ID'}}->{PACKETS}}, $holder);

			# Just move next
			next;
		}		
	
		# Get latest date / time stamp ( IF we haven't found a SIP begin mark )
                if (!$capture && $_ =~ /^\[?(\w{3}\s{1,2}\d{1,2} (\d{2}:){2}\d{2})\]?/)
                {
                        $date_time = $1;
			next unless $_ =~ /ransmitting.*to/;
                }
	
		# Catch an outbound SIP message ( Only necessary if we haven't started capturing a packet
		if (!$capture && $_ =~ /ransmitting.*to (\S+)/)
		{
			# Reset our tmp hash:
			$tmp = {};

			# Set far end host key
			$tmp->{FAR} = $1;

			# If the last character is a : - then trim it ( This is faster than a regex )
			if(rindex($tmp->{FAR}, ':') == 1)
			{
				chop $tmp->{FAR};
			}
			
			# I can set capture here right?
			$capture = 1;

			# Move next
			next;
		}

		# Catch an inbound SIP message ( Again, only necessary if we haven't started capturing )
		if (!$capture && $_ =~ /SIP read from (\S+)/)
		{
			# Reset our tmp hash:
			$tmp = {};

			# Set near end host key
			$tmp->{NEAR} = $1;

			$capture = 1;

			# Move next
			next;
		}
		
		# Check for a SIP method message
		if ($capture && ( /^(REFER|BYE|ACK|INVITE|CANCEL)\s+sip:\s?([a-zA-Z90-9\.\-\_\+]+)/ || /^SIP\/2.0\s+([a-zA-Z0-9\/\.\-\_\+ ]+)/ ))
		{
			# If $2 is set, this means that it must be the DID / Dialed extension
			if($2)
			{
				$tmp->{DID} = $2;	
			}
			$tmp->{METHOD} = $1;

			# Move next
			next;
		}

		# Let's just throw each line into the hash with a key / value split, then deal with the regexing only on the necessary keys
		# HMMMMMM....I think i should go w/ index and use substr to get the key / value pair
		if( my $separator = index $_, $kv_separator )
		{
			my $key = uc substr($_, 0, $separator);
			my $value = substr($_, $separator + length($kv_separator), length($_));
			$value =~ s/^\s+//;

			# Normalize compact headers
			$key = 'CALL-ID'	if $key eq 'I';
			$key = 'TO'		if $key eq 'T';
			$key = 'FROM'		if $key eq 'F';
			$key = 'CONTACT'	if $key eq 'M';
			$key = 'VIA'		if $key eq 'V';
	
			# If this is the callid and it doesn't even match, let's stop collecting by undefining the capture flag
			if($key eq 'CALL-ID' && defined $params->{CALLID} && $value !~ $params->{CALLID})
			{
				message({ DEBUG => $params->{DEBUG}, TYPE => 'DEBUG', MESSAGE => "Skipping CALL-ID " . $value . " because it doesn't match " . $params->{CALLID} });

				# Undef our currently used vars and move next
				$capture = undef;
				$tmp = {};
				next;
			}

			# Man I hope this isn't too expensive
			if(defined $params->{NUMBER} && defined $tmp->{TO} && defined $tmp->{FROM} && $tmp->{TO} !~ /$params->{NUMBER}/ && $tmp->{FROM} !~ /$params->{NUMBER}/)
			{
				message({ DEBUG => $params->{DEBUG}, TYPE => 'DEBUG', MESSAGE => "Skipping CALL-ID " . $value . " because number not found: " . $params->{NUMBER} });
				$capture = undef;
				$tmp = {};
				next;
			}

			# Set the temporary hash key / values
			$tmp->{$key} = $value;
		}
	}

	return $sip;

}

sub show_usage
{
	my $script = $0;
	$script =~ s/^.*\///g;

	print "\n";
	print "Usage: $script [options]\n\n";
	print "\t--verbose	Display verbose messages\n";
	print "\t--debug     	Display debug messages\n";
	print "\t--priority	Do not attempt to lower process priority ( Run at default nice level )\n";
	print "\t--proxy     	Use specified proxy for outbound http connections ( Not yet implemented )\n";
	print "\t--ignore-xdid	Do not attempt to determine the number dialed using X-DID header field\n";
	print "\t--logpath	Location of log file ( Example: $0 --logpath /var/log/asterisk/full )\n\n";
}

sub show_version
{
	my $script = $0;
	$script =~ s/^.*\///g;

	my $params = shift || {};
	print "\n";
	print "$script Version " . $params->{VERSION} . " ( " . $params->{DATE} . " ) \n\n";
	print "\tAuthor: Jeffrey Weitz\n";
	print "\tjeffdoubleyou\@gmail.com\n";
	print "\thttp://www.jeffdoubleyou.com\n\n";
}

sub upgrade_version
{
	#use constant CURRENT_URL        => 'http://www.jeffdoubleyou.com/pub/Downloads/SIPGrapher/sip_grapher_current.pl';
	my $params = shift || {};

	message({ VERBOSE => $verbose, TYPE => 'VERBOSE', MESSAGE => "Attempting upgrade from " . $params->{VERSION} });

	my $script = get(CURRENT_URL);
	unless($script)
	{
		$@ = "Unable to download current version $@";
		return undef;
	}

	unless(open(F, ">/tmp/sip_grapher.tmp"))
	{
		$@ = "Unable to write to temporary file - $!";
		return undef;
	}

	print F $script;

	close(F);

	chmod 755, "/tmp/sip_grapher.tmp";

	my $pid = $$;
	my $command = "/tmp/sip_grapher.tmp --upgrade=$0 --pid=$pid";
	
	fork && system($command);
	exit;
}
