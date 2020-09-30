#!/usr/bin/perl

#
# PLEASE KEEP this test in sync with qatest/backend/api2/13_import_certificate.t
#

use strict;
use warnings;

# Core modules
use FindBin qw( $Bin );

# CPAN modules
use Test::More;

# Project modules
use lib "$Bin/../lib";
use lib "$Bin";
use OpenXPKI::Test;
use CommandlineTest;

plan tests => 20;

#
# Setup test context
#
my $oxitest = OpenXPKI::Test->new(
    with => [ qw( TestRealms CryptoLayer ) ],
);
my $dbdata = $oxitest->certhelper_database;

#
# Tests for IMPORT
#
cert_import_failsok($dbdata->cert("gamma-bob-1"), qr/ unable .* find .* issuer /msxi);
cert_import_ok     ($dbdata->cert("gamma-bob-1"),    '--force-no-chain');

cert_import_ok     ($dbdata->cert("alpha-root-2"),      qw(--realm alpha));
cert_import_failsok($dbdata->cert("alpha-root-2"), qr/ certificate .* already .* exists /msxi);
cert_import_ok     ($dbdata->cert("alpha-root-2"),      qw(--realm alpha), '--force-certificate-already-exists');

cert_import_ok     ($dbdata->cert("alpha-signer-2"),    qw(--realm alpha), '--group' => 'alpha-signer', '--gen' => 2);
cert_import_ok     ($dbdata->cert("alpha-datavault-2"), qw(--realm alpha), '--token' => 'datasafe',     '--gen' => 2);
cert_import_ok     ($dbdata->cert("alpha-scep-2"),      qw(--realm alpha), '--token' => 'scep',         '--gen' => 2);
cert_import_ok     ($dbdata->cert("alpha-alice-2"),     qw(--realm alpha --revoked --alias MelaleucaAlternifolia));

# Import expired certificates
cert_import_ok     ($dbdata->cert("alpha-root-1"),      qw(--realm alpha));
cert_import_ok     ($dbdata->cert("alpha-signer-1"),    qw(--realm alpha));
cert_import_ok     ($dbdata->cert("alpha-alice-1"),     qw(--realm alpha));

my @ids = map { $dbdata->cert($_)->db->{identifier} }
    qw(
        alpha-root-1 alpha-signer-1 alpha-alice-1
        alpha-root-2 alpha-signer-2 alpha-datavault-2 alpha-scep-2 alpha-alice-2
    );
my $a_alice_2_id    = $dbdata->cert("alpha-alice-2")->db->{identifier};
my $a_signer_2_id   = $dbdata->cert("alpha-signer-2")->db->{identifier};
my $a_root_2_id     = $dbdata->cert("alpha-root-2")->db->{identifier};

#
# Tests for LIST
#
cert_list_failsok  qr/realm/i;

# Show certificates with aliases
cert_list_ok
    qr/ \Q$a_alice_2_id\E ((?!identifier).)* MelaleucaAlternifolia /msxi,
    qw(--realm alpha);

# show all certificates of realm
cert_list_ok
    [
        @ids,
        qr/ \Q$a_alice_2_id\E \W+ revoked ((?!identifier).)* MelaleucaAlternifolia /msxi,
    ],
    qw(--realm alpha --all);

# verbose
my @verbose1 = (
    $dbdata->cert("alpha-alice-2")->db->{identifier},
    "MelaleucaAlternifolia", # alias
    $dbdata->cert("alpha-alice-2")->db->{subject},
    $dbdata->cert("alpha-alice-2")->db->{issuer_dn},
);
my @verbose2 = (
    @verbose1,
    qr/ $a_alice_2_id ((?!\n).)* $a_signer_2_id ((?!\n).)* .* $a_root_2_id /msxi # chain
);
my @verbose3 = (
    @verbose2,
    $dbdata->cert("alpha-alice-2")->db->{subject_key_identifier},
    $dbdata->cert("alpha-alice-2")->db->{authority_key_identifier},
    $dbdata->cert("alpha-alice-2")->db->{issuer_identifier},
    qr/ revoked /msxi,
    $dbdata->cert("alpha-alice-2")->db->{notbefore},
    $dbdata->cert("alpha-alice-2")->db->{notafter},
);
my @verbose4 = (
    @verbose3,
    '-----BEGIN CERTIFICATE-----',
);

cert_list_ok \@verbose1, qw(--realm alpha -v);
cert_list_ok \@verbose2, qw(--realm alpha -v -v);
cert_list_ok \@verbose3, qw(--realm alpha -v -v -v);
cert_list_ok \@verbose4, qw(--realm alpha -v -v -v -v);

#
# Test KEY LIST
#
openxpkiadm_test
    [ 'key', 'list' ],
    [ '--realm' => 'alpha' ],
    1,
    [qw( alpha-signer-2 alpha-datavault-2 alpha-scep-2 )],
    'list keys';

#
# Test CHAIN
#

# There is a bug that does not allow parameter --realm
#openxpkiadm_test
#    [ 'certificate', 'chain' ],
#    [ '--realm' => 'alpha', '--name' => $a_alice_2_id, '--issuer' => $a_root_2_id ],
#    1,
#    qr/jens/,
#    'change certificate chain';

# Cleanup database
$oxitest->delete_testcerts;
