#!/usr/bin/perl


use FindBin qw( $Bin );
use lib "$Bin/../lib";
use strict;
use warnings;
use JSON;
use English;
use Data::Dumper;
use Log::Log4perl qw(:easy);
use TestCGI;

use Test::More tests => 4;

package main;

my $result;
my $client = TestCGI::factory('democa');

# create temp dir
-d "tmp/" || mkdir "tmp/";

$result = $client->mock_request({
    'page' => 'workflow!index!wf_type!certificate_signing_request_v2',
});

is($result->{main}->[0]->{content}->{fields}->[2]->{name}, 'wf_token');

$result = $client->mock_request({
    'action' => 'workflow!index',
    'wf_token' => undef,
    'cert_profile' => 'tls_client',
    'cert_subject_style' => '00_basic_style'
});

like($result->{goto}, qr/workflow!load!wf_id!\d+/, 'Got redirect');

my ($wf_id) = $result->{goto} =~ /workflow!load!wf_id!(\d+)/;

diag("Workflow Id is $wf_id");

$result = $client->mock_request({
    'page' => $result->{goto},
});

$result = $client->mock_request({
    'action' => 'workflow!select!wf_action!csr_provide_server_key_params!wf_id!'.$wf_id,
});

$result = $client->mock_request({
    'action' => 'workflow!index',
    'key_alg' => 'rsa',
    'enc_alg' => 'aes256',
    'key_gen_params{KEY_LENGTH}' => 2048,
    'password_type' => 'server',
    'wf_token' => undef
});

$result = $client->mock_request({
    'action' => 'workflow!index',
    'cert_subject_parts{hostname}' => 'testbox.openxpki.org',
    'cert_subject_parts{application_name}' => 'pkitest',
    'wf_token' => undef
});

$result = $client->mock_request({
    'action' => 'workflow!index',
    'wf_token' => undef
});

$result = $client->mock_request({
    'action' => $result->{main}->[0]->{content}->{buttons}->[0]->{action}
});

if ($result->{main}->[0]->{content}->{fields} &&
    $result->{main}->[0]->{content}->{fields}->[0]->{name} eq 'policy_comment') {
    $result = $client->mock_request({
        'action' => 'workflow!index',
        'policy_comment' => 'Testing',
        'wf_token' => undef
    });
}

my $data = $client->prefill_from_result();
my $password = $data->{'_password'};
diag("Password is $password");

$result = $client->mock_request({
    'action' => 'workflow!index',
    '_password' => $password,
    'wf_token' => undef
});

$result = $client->mock_request({
    'action' => 'workflow!select!wf_action!csr_approve_csr!wf_id!' . $wf_id,
});

is ($result->{status}->{level}, 'success', 'Status is success');

my $cert_identifier = $result->{main}->[0]->{content}->{data}->[0]->{value}->{label};
$cert_identifier =~ s/\<br.*$//g;

# Download the certificate
$result = $client->mock_request({
     'page' => 'workflow!index!wf_type!show_metadata',
});

$result = $client->mock_request({
    'action' => 'workflow!index',
    'cert_identifier' => $cert_identifier,
    'wf_token' => undef,
});

# Download the certificate
$result = $client->mock_request({
     'page' => 'workflow!index!wf_type!certificate_privkey_export',
});

$result = $client->mock_request({
    'action' => 'workflow!index',
    'key_format' => 'PKCS12',
    'cert_identifier' => $cert_identifier,
    '_password' => $password,
    'unencrypted' => 1,
    'wf_token' => undef
});

like($result->{goto}, qr/workflow!load!wf_id!\d+/, 'Got redirect');

($wf_id) = $result->{goto} =~ /workflow!load!wf_id!(\d+)/;

diag("Download Workflow Id is $wf_id");

$result = $client->mock_request({
    'page' => $result->{goto},
});

my ($page, $link) = split "=", $result->{main}->[0]->{content}->{data}->[1]->{value}->{page};

$result = $client->mock_request({
    'page' => $link
});

open(CERT, ">tmp/entity26.id");
print CERT $cert_identifier;
close CERT;

open(CERT, ">tmp/entity26.p12");
print CERT $result ;
close CERT;

open(CERT, ">tmp/entity26.pass");
print CERT $password ;
close CERT;

