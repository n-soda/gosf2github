#!/usr/bin/env perl -w
use strict;
use JSON;
use DateTime::Format::Strptime qw/strptime strftime/;

my $json = new JSON;

my $CURL_OPTIONS = $ENV{CURL_OPTIONS};
my $GITHUB_TOKEN;
my $REPO;
my $dry_run=0;
my @collabs = ();
my @ghmilestones = ();
my $sleeptime = 3;
my $maxwaittime = 30;
my $default_assignee;
my $usermap = {};
my $only_milestones = 0;
my $sf_base_url = "https://sourceforge.net/p/";
my $sf_tracker = "";  ## e.g. obo/mouse-anatomy-requests
my @default_labels = ('sourceforge', 'auto-migrated');
my $genpurls;
my $start_from = 1;
while ($ARGV[0] =~ /^\-/) {
    my $opt = shift @ARGV;
    if ($opt eq '-h' || $opt eq '--help') {
        print usage();
        exit 0;
    }
    elsif ($opt eq '-t' || $opt eq '--token') {
        $GITHUB_TOKEN = shift @ARGV;
    }
    elsif ($opt eq '-r' || $opt eq '--repo') {
        $REPO = shift @ARGV;
    }
    elsif ($opt eq '-a' || $opt eq '--assignee') {
        $default_assignee = shift @ARGV;
    }
    elsif ($opt eq '-s' || $opt eq '--sf-tracker') {
        $sf_tracker = shift @ARGV;
    }
    elsif ($opt eq '-d' || $opt eq '--delay') {
        $sleeptime = shift @ARGV;
    }
    elsif ($opt eq '--max-wait-time') {
        $maxwaittime = shift @ARGV;
    }
    elsif ($opt eq '-i' || $opt eq '--initial-ticket') {
        $start_from = shift @ARGV;
    }
    elsif ($opt eq '-l' || $opt eq '--label') {
        push(@default_labels, shift @ARGV);
    }
    elsif ($opt eq '-k' || $opt eq '--dry-run') {
        $dry_run = 1;
    }
    elsif ($opt eq '-M' || $opt eq '--only-milestones') {
        $only_milestones = 1;
    }
    elsif ($opt eq '--generate-purls') {
        # if you are not part of the OBO Library project, you can safely ignore this option;
        # It will replace IDs of form FOO:nnnnn with PURLs
        $genpurls = 1;
    }
    elsif ($opt eq '-c' || $opt eq '--collaborators') {
        @collabs = @{parse_json_file(shift @ARGV)};
    }
    elsif ($opt eq '-u' || $opt eq '--usermap') {
        $usermap = parse_json_file(shift @ARGV);
    }
    elsif ($opt eq '-m' || $opt eq '--milestones') {
        @ghmilestones = @{parse_json_file(shift @ARGV)};
    }
    else {
        die $opt;
    }
}
print STDERR "TICKET JSON: @ARGV\n";

my %collabh = ();
foreach (@collabs) {
    $collabh{$_->{login}} = $_;
}

my $blob = join("",<>);
my $obj = $json->decode( $blob );

my @tickets = @{$obj->{tickets}};
my @milestones = @{$obj->{milestones}};

if ($only_milestones) {
    import_milestones();
    exit 0;
}

my %ghmilestones = ();
foreach (@ghmilestones) {
    $ghmilestones{$_->{title}} = $_;
}

#foreach my $k (keys %$obj) {
#    print "$k\n";
#}

@tickets = sort {
    $a->{ticket_num} <=> $b->{ticket_num}
} @tickets;

foreach my $ticket (@tickets) {
    
    my $custom = $ticket->{custom_fields} || {};
    my $milestone = $custom->{_milestone};
    my $resolution = $custom->{_resolution};
    my $type = $custom->{_type};

    my @labels = (@default_labels,  @{$ticket->{labels}});

    push(@labels, map_priority($custom->{_priority}));

    if ($resolution eq '' || $resolution eq 'fixed') {
	# ignore
    } elsif ($resolution eq 'worksforme') {
	push(@labels, 'invalid');
    } else {
	push(@labels, $resolution);
    }

    if ($type eq 'defect') {
	push(@labels, 'bug');
    } elsif ($type ne '') {
	push(@labels, $type);
    }

    my $assignee = '';
    my $assignee_name = '';
    if ($ticket->{assigned_to}) {
	if (!mappable_user($ticket->{assigned_to})) {
	    # user at SourceForge
	    $assignee_name = map_user($ticket->{assigned_to});
	} else {
	    $assignee = map_user($ticket->{assigned_to});
	    if ($assignee && !$collabh{$assignee}) {
		print STDERR "WARNING: $assignee is not a collaborator\n";
		$assignee_name = $assignee;
		$assignee = '';
	    }
	}
    }
    if (!$assignee) {
        $assignee = $default_assignee;
    }

    my $body = $ticket->{description};

    # fix SF-specific markdown
    $body =~ s/\~\~\~\~/```/g;

    if ($genpurls) {
        my @lines = split(/\n/,$body);
        foreach (@lines) {
            last if m@```@;
            next if m@^\s\s\s\s@;
            s@(\w+):(\d+)@[$1:$2](http://purl.obolibrary.org/obo/$1_$2)@g;
        }
        $body = join("\n", @lines);
    }

    my $created_date = $ticket->{created_date};

    # OK, so I should really use a proper library here...
    $created_date =~ s/\-//g;
    $created_date =~ s/\s.*//g;

    # it is tempting to prefix with '@' but this may generate spam and get the bot banned
    #$body .= "\n\nReported by: \@".map_user($ticket->{reported_by});
    $body .= "\n\nReported by: ".map_user($ticket->{reported_by});
    if ($assignee_name) {
	$body .= "\nOriginally assigned to: ".$assignee_name;
    }

    my $num = $ticket->{ticket_num};
    printf "Ticket: ticket_num: %d of %d total (last ticket_num=%d)\n", $num, scalar(@tickets), $tickets[-1]->{ticket_num};
    if ($num < $start_from) {
        print STDERR "SKIPPING: $num\n";
        next;
    }
    if ($sf_tracker) {
        my $turl = "$sf_base_url$sf_tracker/$num";
        $body .= "\n\nOriginal Ticket: [$sf_tracker/$num]($turl)";
    }

    my $issue =
    {
        "title" => $ticket->{summary},
        "body" => $body,
        "created_at" => cvt_time($ticket->{created_date}),    ## check
        "closed" => $ticket->{status} =~ /([Cc]losed.*|[Ff]ixed|[Dd]one|[Ww]ont.*[Ff]ix|[Vv]erified|[Dd]uplicate|[Ii]nvalid)/ ? JSON::true : JSON::false ,
        "labels" => \@labels,
    };

    if ($assignee) {
        $issue->{assignee} = $assignee;
    }

    # Declare milestone if possible
    if ($ghmilestones{$milestone}) {
        $issue->{milestone} = $ghmilestones{$milestone}->{number};
    }
    # Else, use a tag
    elsif ($milestone) {
        push(@{$issue->{labels}}, $milestone);
    }

    my @comments = ();
    foreach my $post (@{$ticket->{discussion_thread}->{posts}}) {
        my $comment =
        {
            "created_at" => cvt_time($post->{timestamp}),
            "body" => $post->{text}."\n\nOriginal comment by: ".map_user($post->{author}),
        };
        push(@comments, $comment);
    }

    my $req = {
        issue => $issue,
        comments => \@comments
    };
    my $str = $json->utf8->encode( $req );
    #print $str,"\n";
    my $jsfile = 'foo.json';
    open(F,">$jsfile") || die $jsfile;
    print F $str;
    close(F);

    #  https://gist.github.com/jonmagic/5282384165e0f86ef105
    my $ACCEPT = "application/vnd.github.golden-comet-preview+json";
    #my $ACCEPT = "application/vnd.github.v3+json";   # https://developer.github.com/v3/

    my $command = "curl ${CURL_OPTIONS} -f -X POST -H \"Authorization: token $GITHUB_TOKEN\" -H \"Accept: $ACCEPT\" -d \@$jsfile https://api.github.com/repos/$REPO/import/issues\n";
    print $command;
    if ($dry_run) {
        print "DRY RUN: not executing\n";
        print "$str\n";
    }
    else {
        # yes, I'm really doing this via a shell call to curl, and not
        # LWP or similar, I prefer it this way
        my $err = system($command);
        if ($err) {
            print STDERR "FAILED: $command\n";
            print STDERR "Retrying once...\n";
            # HARDCODE ALERT: do a single retry
            sleep($sleeptime * 5);
            $err = system($command);
            if ($err) {
                print STDERR "FAILED: $command\n";
                print STDERR "To resume, use the -i $num option\n";
                exit(1);
            }
        }

        # Verify ticket was properly created. If not, stop importing.
        sleep(2);
	my $waittime = 0;
        my $command = "curl ${CURL_OPTIONS} -s -f -o /dev/null -H \"Authorization: token $GITHUB_TOKEN\" -H \"Accept: $ACCEPT\" https://api.github.com/repos/$REPO/issues/$num\n";
        print $command;
	for (;;) {
	    $err = system($command);
	    if (($? >> 8) == 22) {
		if ($waittime > $maxwaittime) {
		    print STDERR "$err\n";
		    print STDERR "Ticket not created. Stopping\n";
		    exit 1;
		}
		sleep(2);
		$waittime += 2;
		print "retry: " . $command;
		next;
	    }
	    last;
	}
    }
    #die;
    sleep($sleeptime);
}


exit 0;

sub import_milestones {

    foreach(@milestones) {
        my $milestone = {
            "title" => $_->{name},
            "state" => $_->{complete} ? 'closed' : 'open',
            "description" => $_->{description},
        };

        # Add due_date if defined
        if ($_->{due_date}) {
            my $dt = strptime("%m/%d/%Y", $_->{due_date});
            $milestone->{due_on} = strftime("%FT%TZ", $dt);
        }

        my $str = $json->utf8->encode($milestone);
        my $jsfile = 'foo.json';
        open(F,">$jsfile") || die $jsfile;
        print F $str;
        close(F);

        my $ACCEPT = "application/vnd.github.v3+json";   # https://developer.github.com/v3/
        my $command = "curl ${CURL_OPTIONS} -f -X POST -H \"Authorization: token $GITHUB_TOKEN\" -H \"Accept: $ACCEPT\" -d \@$jsfile https://api.github.com/repos/$REPO/milestones\n";
        print $command;
        if ($dry_run) {
            print "DRY RUN: not executing\n";
            print "$str\n";
        }
        else {
            # yes, I'm really doing this via a shell call to curl, and not
            # LWP or similar, I prefer it this way
            my $err = system($command);
            if ($err) {
                print STDERR "FAILED: $command\n";
                print STDERR "Retrying once...\n";
                # HARDCODE ALERT: do a single retry
                sleep($sleeptime * 5);
                $err = system($command);
                if ($err) {
                    print STDERR "FAILED: $command\n";
                    exit(1);
                }
            }
        }
        #die;
        sleep($sleeptime);
    }

}

sub parse_json_file {
    my $f = shift;
    open(F,$f) || die $f;
    my $blob = join('',<F>);
    close(F);
    return $json->decode($blob);
}

sub mappable_user {
    my $u = shift;
    return $u && $usermap->{$u};
}

sub map_user {
    my $u = shift;
    if ($u) {
	my $ghu = $usermap->{$u};
	if ($ghu) {
	    return $ghu;
	} else {
	    return $u . ' at SourceForge'
	}
    }
    return '';
}

sub cvt_time {
    my $in = shift;  # 2013-02-13 00:30:16
    $in =~ s/ /T/;
    return $in."Z";
    
}

# customize this?
sub map_priority {
    my $pr = shift;
    return ();
}

sub scriptname {
    my @p = split(/\//,$0);
    pop @p;
}


sub usage {
    my $sn = scriptname();

    <<EOM;
$sn [-h] [-u USERMAP] [-m MILESTONES] [-c COLLABINFO] [-r REPO] [-t OAUTH_TOKEN] [-a USERNAME] [-l LABEL]* [-s SF_TRACKER] [--dry-run] [--only-milestones] TICKETS-JSON-FILE

Migrates tickets from sourceforge to github, using new v3 GH API, documented here: https://gist.github.com/jonmagic/5282384165e0f86ef105

Requirements:

 * This assumes that you have exported your tickets from SF. E.g. from a page like this: https://sourceforge.net/p/obo/admin/export
 * You have a github account and have created an OAuth token here: https://github.com/settings/tokens
 * You have "curl" in your PATH

Example Usage:

curl -H "Authorization: token TOKEN" https://api.github.com/repos/obophenotype/cell-ontology/collaborators > cell-collab.json
gosf2github.pl -a cmungall -u users_sf2gh.json -c cell-collab.json -r obophenotype/cell-ontology -t YOUR-TOKEN-HERE cell-ontology-sf-export.json 



ARGUMENTS:

   -k | --dry-run
                 Do not execute github API calls; print curl statements instead

   -r | --repo   REPO *REQUIRED*
                 Examples: cmungall/sf-test, obophenotype/cell-ontology

   -t | --token  TOKEN *REQUIRED*
                 OAuth token. Get one here: https://github.com/settings/tokens
                 Note that all tickets and issues will appear to originate from the user that generates the token.
                 Important: make sure the token has the public_repo scope.

   -c | --collaborators COLLAB-JSON-FILE *REQUIRED*
                  Required, as it is impossible to assign to a non-collaborator
                  Generate like this:
                  curl -H "Authorization: token TOKEN" https://api.github.com/repos/cmungall/sf-test/collaborators > sf-test-collab.json

   -u | --usermap USERMAP-JSON-FILE *RECOMMENDED*
                  Maps SF usernames to GH
                  Example: https://github.com/geneontology/go-site/blob/master/metadata/users_sf2gh.json

   -m | --milestones MILESTONES-JSON-FILE/
                 If provided, link ticket to proper milestone. It not, milestone will be declared as a ticket label.
                 Generate like this:
                 curl -H "Authorization: token TOKEN" https://api.github.com/repos/cmungall/sf-test/milestones?state=all > milestones.json

   -a | --assignee  USERNAME *RECOMMENDED*
                 Default username to assign tickets to if there is no mapping for the original SF assignee in usermap

   -l | --label  LABEL
                 Add this label to all tickets, in addition to defaults and auto-added.
                 Currently the following labels are ALWAYS added: auto-migrated, a priority label (unless priority=5), a label for every SF label, a label for the milestone

   -i | --initial-ticket  NUMBER
                 Start the import from (sourceforge) ticket number NUM. This can be useful for resuming a previously stopped or failed import.
                 For example, if you have already imported 1-100, then the next github number assigned will be 101 (this cannot be controlled).
                 You will need to run the script again with argument: -i 101

   -s | --sf-tracker  NAME
                 E.g. obo/mouse-anatomy-requests
                 If specified, will append the original URL to the body of the new issue. E.g. https://sourceforge.net/p/obo/mouse-anatomy-requests/90

   -M | --only-milestones
                 Only import milestones defined in data exported from SF, from TICKETS-JSON-FILE.
                 Useful to run this script first, with this flag to populate GitHub milestones and use them really imported SF tickets.

   --generate-purls
                 OBO Ontologies only: converts each ID of the form `FOO:nnnnnnn` into a PURL.
                 If this means nothing to you, the option is not intended for you. You can safely ignore it.

NOTES:

 * uses a pre-release API documented here: https://gist.github.com/jonmagic/5282384165e0f86ef105
 * milestones are converted to labels
 * all issues and comments will appear to have originated from the user who issues the OAth ticket
 * confirm your rate limit for "core" before you start to ensure you have sufficient requests
   remaining to import your number of tickets. The script makes no effort to do this for you.

   curl -H "Authorization: token TOKEN" https://api.github.com/rate_limit

 * NEVER RUN TWO PROCESSES OF THIS SCRIPT IN THE SAME DIRECTORY - see notes on json hack below

HOW IT WORKS:

The script iterates through every ticket in the json dump. For each
ticket, it prepares an API post request to the new GitHub API.

The contents of the request are placed in a directory `foo.json` in
your home dir, and then this is fed via a command line call to
`curl`. Yes, this is hacky but I prefer it this way. Feel free to
submit a fix via pull request if this bothers you.

(warning: because if this you should never run >1 instance of this
script at the same time in the same directory)

The script will then sleep for 3s before continuing on to the next ticket.
 * all issues and comments will appear to have originated from the user who issues the OAuth token

TIP:

Note that the API does not grant permission to create the tickets as
if they were created by the original user, so if your token was
generated from your account, it will look like you submitted the
ticket and comments.

Create an account for an agent like https://github.com/bbopjenkins -
use this account to generate the token. This may be better than having
everything show up under your own personal account

The account requires admin privileges for the repository.

CREDITS:

Author: [Chris Mungall](https://github.com/cmungall)
Inspiration: https://github.com/ttencate/sf2github
Thanks: Ivan Žužak (GitHub support), Ville Skyttä (https://github.com/scop)

EOM
}
