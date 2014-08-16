


#sip_grapher

This program is used to scrape Asterisk log files and build graphs displaying the SIP session for a
given call using SIP debug messages.

Search by phone number or Call-ID

Version 2.6

Date: 05/04/2010

Author:

	Jeffrey Weitz
	jeffdoubleyou@gmail.com
	jeffdoubleyou.com


Changelog:

	2.0 - 03/06/2010
	
		1. Initial re-write of sip_grapher.pl version 1.0

	2.1 - 03/08/2010 

		1. Fixed CANCEL transaction
		2. Automated version check and upgrading
		3. Help and usage fixes
		
	2.2 - 03/13/2010

		1. Fixed issue with non phone calls ( registration, options, etc. ) were being used
		   when searching for matching calls.

		2. Fixed multiple call selection - only one graph was produced due to backwards
		   matching of call ID vs list.

		3. If there are no matching calls, it won't ask you to select a call.

		4. Fixed SIP messages with / such as Call Leg/Transaction does not exist - where
		   previously it would only show Call Leg.

	2.3 - 03/19/2010

		1. Added date / time in each SIP message for ease of reading

	2.4 - 03/31/2010

		1. Fixed certain types of SIP packets not being read ( Thanks Monica! )

	2.5 - 04/06/2010

		1. Now supports E.164 formatted phone numbers in packets

	2.6 - 05/04/2010

		1. Fixed issue with selecting log file path ( forgot to allow input )

		2. Fixed log file selection numbers where there would always be two extra entries.

		3. Cleaned up STDIN input for mode / call-id / number input




