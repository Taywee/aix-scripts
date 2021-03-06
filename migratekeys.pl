#!/usr/bin/perl
# Copyright © 2015 Taylor C. Richberger <taywee@gmx.com>
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use warnings;
use strict;

use Pod::Usage;

sub Main;

exit Main();

sub Main
{
    if ((scalar(@ARGV) > 0) && grep(/^-h$/, @ARGV))
    {
        pod2usage({-verbose => 2, -exitval => 0, -output => \*STDERR});
        return 0;
    } elsif ($> != 0)
    {
        pod2usage({-msg => 'This program must be run as root', -verbose => 0, -exitval => 1, -output => \*STDERR});
        return 1;
    } elsif (scalar(@ARGV) < 2)
    {
        pod2usage({-verbose => 1, -exitval => 1, -output => \*STDERR});
        return 1;
    }
    my %passwd;

    # Build a passwd list that is referenced by username
    setpwent();
    while (my @pw = getpwent())
    {
        my $hash = {};

        ($hash->{name}, $hash->{passwd}, $hash->{uid}, $hash->{gid}, $hash->{quota}, $hash->{comment}, $hash->{gcos}, $hash->{dir}, $hash->{shell}, $hash->{expire}) = @pw;

        $passwd{$hash->{name}} = $hash;
    }
    endpwent();

    # Same thing, but for LDAP users, because getpwnam properly gets an ldap
    # user, but getpwent doesn't iterate over them.
    my $rc = open(my $lsuser, '-|', 'lsuser -R LDAP -a ALL 2>/dev/null');

    if ($rc)
    {
        while (my $line = <$lsuser>)
        {
            chomp($line);
            next if (length($line) == 0);
            my @pw = getpwnam($line);
            my $hash = {};

            ($hash->{name}, $hash->{passwd}, $hash->{uid}, $hash->{gid}, $hash->{quota}, $hash->{comment}, $hash->{gcos}, $hash->{dir}, $hash->{shell}, $hash->{expire}) = @pw;

            $passwd{$hash->{name}} = $hash;
        }
        close($lsuser);
    }

    my $host = shift(@ARGV);
    my @users;

    # Check that all users exist first
    for my $user (@ARGV)
    {
        if (!defined($passwd{$user}))
        {
            pod2usage({-msg => "User $user does not exist on the host", -verbose => 1, -exitval => 1, -output => \*STDERR});
        }

        my %hash;
        $hash{name} = $user;
        $hash{dir} = $passwd{$user}{dir};
        $hash{uid} = $passwd{$user}{uid};
        $hash{gid} = $passwd{$user}{gid};
        $hash{group} = getgrgid($hash{gid});

        push(@users, \%hash);
    }

    umask(0077);

    # Check their directories, create their keys if necessary, and pull their public keys into their hash.
    for my $user (@users)
    {
        if (! -e "$user->{dir}/.ssh/id_rsa.pub")
        {
            mkdir("$user->{dir}");
            chown($user->{uid}, $user->{gid}, "$user->{dir}");
            mkdir("$user->{dir}/.ssh");
            chown($user->{uid}, $user->{gid}, "$user->{dir}/.ssh");
            system("su $user->{name} -c \"ssh-keygen -t rsa -N '' -f $user->{dir}/.ssh/id_rsa\"");
        }
        open(my $pubkey, '<', "$user->{dir}/.ssh/id_rsa.pub") or die "could not open $user->{name}'s pubkey: $!";

        my $keystring = <$pubkey>;
        close($pubkey);
        chomp($keystring);
        $user->{pubkey} = $keystring;

        print("$user->{name}: $user->{pubkey}\n");
    }

    my $remotescriptname = "/tmp/migratekeys_remote-" . time() . '.pl';

    open(my $fh, '>', $remotescriptname) || die "Could not open remote script name: $remotescriptname";
    print($fh "#!/usr/bin/perl\nsub Touch;\n");
    print($fh 'my @users = (');

    # Print user list to be added, with keys and group names
    my $firstuser = 1;
    for my $user (@users)
    {
        my $out = '';
        if (!$firstuser)
        {
            $out .= ', ';
        }

        $out .= "['$user->{name}', '$user->{group}', '$user->{pubkey}']";

        print($fh $out);

        $firstuser = 0;
    }

    print($fh ");\n");

    print($fh q^
umask(0700);

my $action = $ARGV[0];

for my $user (@users)
{
    my $username = $user->[0];
    my $group = $user->[1];
    my $pubkey = $user->[2];

    # Create the group if it doesn't exist
    setgrent();
    my @gr = getgrnam($group);
    if (!@gr)
    {
        system("groupadd $group");
    }
    endgrent();

    setpwent();
    my @pw = getpwnam($username);
    if (!@pw)
    {
        print("creating user $username\n");
        system("useradd -g $group -m $username");
    }
    endpwent();

    if ($action ne 'check')
    {
        my $uid = $pw[2];
        my $gid = $pw[3];
        my $dir = $pw[7];
        print("user $username, uid $uid, gid $gid, home $dir\n");

        if (defined($uid) && defined($gid) && defined($dir))
        {
            my $sshdir = "$dir/.ssh";

            if (! -e "$sshdir/id_rsa.pub")
            {
                print("Making ssh dir at $sshdir\n");
                mkdir($dir);
                chown($uid, $gid, $dir);
                mkdir($sshdir);
                chown($uid, $gid, $sshdir);
            }

            my $authkeysfile = "$dir/.ssh/authorized_keys";

            print("Creating auth keys file at $authkeysfile\n");
            Touch($authkeysfile);
            chown($uid, $gid, $dir, $sshdir, $authkeysfile);
            chmod(0700, $dir, $sshdir, $authkeysfile);

            open(my $fh, '>>', $authkeysfile) || die "Could not write to authkeys file: $!";
            print($fh "$pubkey\n");
            close($fh);
        } else
        {
            print("$username HAS UNDEFINED ATTRIBUTES!  SKIPPING SSH KEY SHIPPING!\n");
        }
    }
}

sub Touch
{
    my $filename = $_[0];
    open(my $fh, '>>', $filename);
    close($fh);
}
^);
    close($fh);

    system("scp $remotescriptname $host:$remotescriptname");
    # Must run script twice to allow user to be created and then queried
    system("ssh -t $host 'sudo perl $remotescriptname check && sudo perl $remotescriptname && rm $remotescriptname'");
    unlink($remotescriptname);
}

=pod

=encoding utf-8

=head1 NAME

migratekeys.pl

=head1 SYNOPSIS

migratekeys.pl {-h} [hostname] [users...]

=head1 OPTIONS

=over 16

=item C<-h>

Show this help menu

=back

=head1 ARGUMENTS

=over 16

=item C<hostname>

The host to connect to.  This is put in as exactly pasted, so if you would like
to use a different user, use user@hostname

=item C<users...>

The users which are managed on the remote side.  Only the users listed are
affected.

=back

=head1 DESCRIPTION

Migrate ssh keys for a list of users to another machine.  The current user must
be root, and the connected user must have sudo access on the destination
machine (we want to avoid ssh in as root, as that fails often).

This program first checks all the local users for existence and for the
existence of their ssh keys.  Any nonexisting local users will cause an error
condition and exit this program immediately.  If a user has no ssh key pair in
the default location, it will be created.  This script builds another script
locally (which is the real workhorse) that is shipped across the wire and
executed with sudo.  This script checks the existence of a user, creates them
if they do not exist, creates their ssh keys if they do not exist, creates
their authorized_keys file if it does not exist with the proper permissions,
and then appends the local host's keys to their file.

=head1 LICENSE

Copyright © 2015 Taylor C. Richberger <taywee@gmx.com>
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
