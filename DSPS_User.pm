package DSPS_User;

use FreezeThaw qw(freeze thaw);
use DSPS_Debug;
use DSPS_Util;
use DSPS_String;
use strict;
use warnings;

use base 'Exporter';
our @EXPORT = ('%g_hUsers', '%g_hAmbigNames');

our %g_hUsers;
our %g_hAmbigNames;
my %hDedupeByMessage;
my $iLastDedupeMaintTime;


sub createUser {
	my $rhUser = {
		name => $_[0],
		regex => $_[1],
		phone => $_[2],
        group => $_[3],
		access_level => $_[4] || 0,
        auto_include => '',
        macros => {},
		filter_recoveries => 0,
		vacation_end => 0,
		auto_reply_text => '',
		auto_reply_expire => 0,
        throttle => 0,
	};

    $g_hUsers{$_[2]} = $rhUser;
    debugLog(D_users, "created $_[0] ($_[2]) of $_[3]");

    return $rhUser;
}


sub previouslySentTo($$) {
    my $iSender = shift;
    my $sMessage = shift;
    my $iNow = time();

    if (defined $hDedupeByMessage{$sMessage}) {
        if ($hDedupeByMessage{$sMessage} =~ /\b$iSender:(\d+)\b/) {
            my $iTime = $1;
            return 1 if ($iTime > $iNow - 172800);

            $hDedupeByMessage{$sMessage} =~ s/$iSender:$iTime/$iSender:$iNow/;
            return 0;
        }
    }

    $hDedupeByMessage{$sMessage} = ($hDedupeByMessage{$sMessage} ? $hDedupeByMessage{$sMessage} : '') . " $iSender:" . $iNow;
    return 0;
}


sub getAutoReply($) {
    my $iUser = shift;

    if ($g_hUsers{$iUser}->{auto_reply_text} && $g_hUsers{$iUser}->{auto_reply_expire}) {
        if ($g_hUsers{$iUser}->{auto_reply_expire} > time()) {
            return $g_hUsers{$iUser}->{auto_reply_text};
        }
        else {
            infoLog("auto reply for user " . $g_hUsers{$iUser}->{name} . " has expired; deleting.");
            $g_hUsers{$iUser}->{auto_reply_expire} = 0;
            $g_hUsers{$iUser}->{auto_reply_text} = '';
        }
    }

    return '';
}



sub freezeState() {
    my %hUserState;

    # create a hash of the user configurable settings
    foreach my $iUser (keys %g_hUsers) {
        $hUserState{$iUser}->{filter_recoveries} = $g_hUsers{$iUser}->{filter_recoveries};
        $hUserState{$iUser}->{vacation_end} = $g_hUsers{$iUser}->{vacation_end};
        $hUserState{$iUser}->{auto_reply_text} = $g_hUsers{$iUser}->{auto_reply_text};
        $hUserState{$iUser}->{auto_reply_expire} = $g_hUsers{$iUser}->{auto_reply_expire};
        $hUserState{$iUser}->{macros} = $g_hUsers{$iUser}->{macros};
    }

   return freeze(%hUserState);
}


sub thawState($) {
    my %hUserState;

    eval { %hUserState = thaw(shift); };
    return infoLog("Unable to parse user state data - ignoring") if ($@);

    foreach my $iUser (keys %hUserState) {

        # we only want to update information for users that already exist.  users will already
        # exist after a restart because they're created by readConfig().  by only restoring
        # attributes of existing users that allows users the admin has deleted from the config
        # file to fall out of the state data too.
        if (defined $g_hUsers{$iUser}) {
            $g_hUsers{$iUser}->{filter_recoveries} = $hUserState{$iUser}->{filter_recoveries};
            $g_hUsers{$iUser}->{vacation_end} = $hUserState{$iUser}->{vacation_end};
            $g_hUsers{$iUser}->{auto_reply_text} = $hUserState{$iUser}->{auto_reply_text};
            $g_hUsers{$iUser}->{auto_reply_expire} = $hUserState{$iUser}->{auto_reply_expire};
            $g_hUsers{$iUser}->{macros} = $hUserState{$iUser}->{macros};
            debugLog(D_state, "restored state data for user " . $g_hUsers{$iUser}->{name});
        }
    }
}


sub matchUserByName($) {
    my $sName = shift;

    foreach my $sPhone (keys %g_hUsers) {
        debugLog(D_users, "checking $sName against " . $g_hUsers{$sPhone}->{name});
        if (lc($sName) eq lc($g_hUsers{$sPhone}->{name})) {
            return $sPhone;
        }
    }

    return '';
}



sub matchUserByRegex($) {
    my $sName = shift;

    foreach my $sPhone (keys %g_hUsers) {
        if ($sName =~ /\b($g_hUsers{$sPhone}->{regex})\b/i ) {
            return $sPhone;
        }
    }

    return '';
}



sub usersInGroup($) {
    my $sTargetGroup = shift;
    my @aUsers;

    foreach my $iUser (keys %g_hUsers) {
        push(@aUsers, $iUser) if ($g_hUsers{$iUser}->{group} eq $sTargetGroup);
    }

    return @aUsers;
}



sub allGroups() {
    my %hGroups;

    foreach my $iUser (keys %g_hUsers) {
        $hGroups{$g_hUsers{$iUser}->{group}} = 1 if $g_hUsers{$iUser}->{group};
    }

    return keys(%hGroups);
}


sub humanTest($) {
    my $sName = shift;

    return ($sName !~ /^\!/);
}


sub humanUsersPhone($) {
    my $iUser = shift;

    return (defined $g_hUsers{$iUser} ? humanTest($g_hUsers{$iUser}->{name}) : 0);
}



sub usersHealthCheck() {
    my $iNow = time();

    foreach my $iUser (keys %g_hUsers) {
        if ($g_hUsers{$iUser}->{vacation_end} && ($g_hUsers{$iUser}->{vacation_end} <= $iNow)) {
            $g_hUsers{$iUser}->{vacation_end} = 0;
            infoLog($g_hUsers{$iUser}->{name} . "'s vacation time has expired");
            main::sendEmail(main::getAdminEmail(), '', sv(E_VacationElapsed1, $g_hUsers{$iUser}->{name}));
        }
    }

    if ($iLastDedupeMaintTime < $iNow - 3600) {
        $iLastDedupeMaintTime = $iNow;
        debugLog(D_users, "cleaning up deduping hash");

        foreach my $sMessage (keys %hDedupeByMessage) {
            my $sData = $hDedupeByMessage{$sMessage};

            foreach my $iPhone (split(/\s+/, $sData)) {
                if ($sData =~ /\b$iPhone:(\d+)\b/) {
                    my $iTime = $1;
                    $sData =~ s/$iPhone:$iTime// if ($iTime < $iNow - 172800);
                }
            }

            delete $hDedupeByMessage{$sMessage} if ($sData =~ /^\s*$/);
        }
    }
}



sub blockedByFilter($$$) {
    my $iPhone = shift;
    my $rMessage = shift;
    my $iLastProblemTime = shift;
    my $sMessage = ${$rMessage};
    my $iNow = time();
    my $sRecoveryRegex = main::getRecoveryRegex();
    use constant THROTTLE_PAGES => 5;

    # FITLER:  Recoveries per user
    if ($sRecoveryRegex && ($g_hUsers{$iPhone}->{filter_recoveries} == 1) && ($sMessage =~ /$sRecoveryRegex/)) {
        infoLog($g_hUsers{$iPhone}->{name} . " has recoveries filtered; not sending copy of message to " . $iPhone);
        return 1;
    }

    # FITLER:  Smart recoveries per user
    # Smart recoveries means to let the recovery through if it during the day or [when night] if it's within 3 minutes
    # of the last problem page
    if ($sRecoveryRegex && ($g_hUsers{$iPhone}->{filter_recoveries} == 2) && ($sMessage =~ /$sRecoveryRegex/) &&
        !isDuringWakingHours() && ($iNow - $iLastProblemTime > 180)) {
        infoLog($g_hUsers{$iPhone}->{name} . " has smart recoveries enabled; not sending copy of message to " . $iPhone);
        return 1;
    }

    # FILTER:  Rate Throttling
    if (($g_hUsers{$iPhone}->{throttle}) && ($g_hUsers{$iPhone}->{throttle} =~ /(\d+)\/(\d+)/)) {
        my $iCount = $1;
        my $iLastTime = $2;

        if ($iNow - $iLastTime > 60) {
            $g_hUsers{$iPhone}->{throttle} = '1/' . $iNow;
        }
        else {
            $g_hUsers{$iPhone}->{throttle} = $iCount+1 . '/' . $iNow;

            if ($iCount > THROTTLE_PAGES - 1) {
                infoLog("PAGE THROTTLED ($iPhone): $sMessage");
                return 1;
            }
            elsif ($iCount == THROTTLE_PAGES - 1) {
                $$rMessage = 'Throttled::' . $sMessage;
            }
        }
    }
    else {
        $g_hUsers{$iPhone}->{throttle} = '1/' . $iNow;
    }

    return 0;
}



1;

