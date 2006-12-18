# OpenXPKI::Server::Workflow::Activity::CRLIsssuance::PublishCRL
# Written by Alexander Klink for the OpenXPKI project 2006
# Copyright (c) 2006 by The OpenXPKI Project
# $Revision$

package OpenXPKI::Server::Workflow::Activity::CRLIssuance::PublishCRL;

use strict;
use base qw( OpenXPKI::Server::Workflow::Activity );

use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Exception;
use OpenXPKI::Debug 'OpenXPKI::Server::Workflow::Activity::CRLIssuance::PublishCRL';
use OpenXPKI::Serialization::Simple;
use OpenXPKI::FileUtils;
use DateTime;
use Net::LDAP;

use Data::Dumper;

sub execute {
    ##! 1: 'execute'
    my $self       = shift;
    my $workflow   = shift;
    my $serializer = OpenXPKI::Serialization::Simple->new();
    my $context    = $workflow->context();

    my $context_ca_ids = $context->param('ca_ids');

    # TODO: avoid code duplication
    my $ca_ids_ref = $serializer->deserialize($context_ca_ids);
    if (!defined $ca_ids_ref) {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_ACTIVITY_CRLISSUANCE_PUBLISHCRL_CA_IDS_NOT_DESERIALIZED",
        );
    }
    if (!ref $ca_ids_ref eq 'ARRAY') {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_ACTIVITY_CRLISSUANCE_PUBLISHCRL_CA_IDS_WRONG_TYPE",
        );
    }
    my @ca_ids = @{$ca_ids_ref};
    if (scalar @ca_ids == 0) {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_ACTIVITY_CRLISSUANCE_PUBLISHCRL_CA_NO_CAS_LEFT",
        );
    }
    
    my $current_ca = $ca_ids[0];
    my $pki_realm = CTX('api')->get_pki_realm();
    my $ca_identifier = CTX('pki_realm')->{$pki_realm}->{ca}->{id}->{$current_ca}->{identifier};
    ##! 16: 'ca_identifier: ' . $ca_identifier
    my $crl_files = CTX('pki_realm')->{$pki_realm}->{ca}->{id}->{$current_ca}->{'crl_files'};
    ##! 16: 'ref crl_files: ' . ref $crl_files
    if (ref $crl_files ne 'ARRAY') {
	OpenXPKI::Exception->throw (
	    message => "I18N_OPENXPKI_ACTIVITY_CRLISSUANCE_PUBLISHCRL_CRL_FILES_IS_NOT_ARRAYREF",
        );
    }
    # FIXME: iterate over all <issue_for> identifiers, if present
    my $dbi = CTX('dbi_backend');
    my $crl_db = $dbi->first(
        TABLE   => 'CRL',
        DYNAMIC => {
            'ISSUER_IDENTIFIER' => $ca_identifier,
            'PUBLICATION_DATE'  => -1, # this CRL has not been published yet
        },
    );
    if (! defined $crl_db) {
	OpenXPKI::Exception->throw(
	    message => "I18N_OPENXPKI_ACTIVITY_CRLISSUANCE_PUBLISHCRL_NO_CRL_IN_DB",
        );
    }
    my $crl = $crl_db->{DATA};
    ##! 16: 'crl: ' . $crl

    foreach my $file (@{$crl_files}) {
        my $filename = $file->{FILENAME};
        my $format   = $file->{FORMAT};
        ##! 16: 'filename: ' . $filename
        ##! 16: 'format: ' . $format
        my $content;
        if ($format eq 'PEM') {
            $content = $crl;
        }
        elsif ($format eq 'DER') {
            my $tm = CTX('crypto_layer');
            my $default_token = $tm->get_token(
                TYPE      => 'DEFAULT',
                PKI_REALM => $pki_realm,
            );
            $content = $default_token->command({
                COMMAND => 'convert_crl',
                DATA    => $crl,
                OUT     => 'DER',
            });
        }
        else {
	    OpenXPKI::Exception->throw(
	        message => "I18N_OPENXPKI_ACTIVITY_CRLISSUANCE_PUBLISHCRL_UNSUPPORTED_OUTPUT_FORMAT",
            );
        }
        my $fu = OpenXPKI::FileUtils->new();
        $fu->write_file({
            FILENAME => $filename,
            CONTENT  => $content,
            FORCE    => 1,
        });
    }
    # do LDAP publication if configured
    my $config = CTX('xml_config');

    my $ldap_servers = 0;
    my $realm_index; 
    my $nr_of_realms = $config->get_xpath_count(XPATH => [ 'pki_realm' ]);
    ##! 64: 'nr of realms: ' . $nr_of_realms

    SEARCH_REALM_INDEX:
    for (my $i = 0; $i < $nr_of_realms; $i++) {
        next SEARCH_REALM_INDEX if ($pki_realm ne $config->get_xpath(
                                    XPATH   => [ 'pki_realm', 'name' ],
                                    COUNTER => [ $i,          0]));
        $realm_index = $i;
        last SEARCH_REALM_INDEX;
    }
    ##! 64: 'realm_index: '  . $realm_index

    my $nr_of_cas = $config->get_xpath_count(
                        XPATH   => [ 'pki_realm', 'ca' ],
                        COUNTER => [ $realm_index ],
    );

    my $ca_index;
    SEARCH_CA_INDEX:
    for (my $i = 0; $i < $nr_of_cas; $i++) {
        next SEARCH_CA_INDEX if ($current_ca ne $config->get_xpath(
                                    XPATH   => [ 'pki_realm' , 'ca', 'id' ],
                                    COUNTER => [ $realm_index, $i, 0 ]));
        $ca_index = $i;
        last SEARCH_CA_INDEX;
    }
    ##! 64: 'ca index: ' . $ca_index

    eval {
        $ldap_servers = $config->get_xpath_count(
            XPATH   => [ 'pki_realm' , 'ca'     , 'crl_publication', 'ldap' ],
            COUNTER => [ $realm_index, $ca_index, 0 ],
        );
    };
    for (my $i = 0; $i < $ldap_servers; $i++) {
        my @basepath = ('pki_realm', 'ca', 'crl_publication', 'ldap');
        my @basectr = ($realm_index, $ca_index, 0, $i);
        my $ldap_server = $config->get_xpath(
            XPATH   => [ @basepath, 'server' ],
            COUNTER => [ @basectr , '0'],
        );
        my $ldap_port = $config->get_xpath(
            XPATH   => [ @basepath, 'port' ],
            COUNTER => [ @basectr , '0'],
        );
        my $ldap_bind_dn = $config->get_xpath(
            XPATH   => [ @basepath, 'bind_dn' ],
            COUNTER => [ @basectr , '0'],
        );
        my $ldap_pass = $config->get_xpath(
            XPATH   => [ @basepath, 'pass' ],
            COUNTER => [ @basectr , '0'],
        );
        my $ldap_base_dn = $config->get_xpath(
            XPATH   => [ @basepath, 'base_dn' ],
            COUNTER => [ @basectr , '0'],
        );
        my $ldap_search_dn = $config->get_xpath(
            XPATH   => [ @basepath, 'search_dn' ],
            COUNTER => [ @basectr , '0'],
        );
        if (! $ldap_server || ! $ldap_port    || ! $ldap_bind_dn ||
            ! $ldap_pass   || ! $ldap_base_dn || ! $ldap_search_dn) {
            OpenXPKI::Exception->throw(
                message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_CRLISSUANCE_PUBLISHCRL_LDAP_CONFIGURATION_BROKEN',
            );
        }
        ##! 2: 'connecting to ldap server ' . $ldap_server . ':' . $ldap_port
        my $ldap = Net::LDAP->new(
            "$ldap_server",
            port    => $ldap_port,
            onerror => undef,
        );

        ##! 2: 'ldap object created'

        if (! defined $ldap) {
            OpenXPKI::Exception->throw(
                message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_CRLISSUANCE_PUBLISHCRL_LDAP_CONNECTION_FAILED',
                params => {
                    'LDAP_SERVER' => $ldap_server,
                    'LDAP_PORT'   => $ldap_port,
                },
            );
        }

        my $mesg = $ldap->bind(
                        $ldap_bind_dn,
                        password => $ldap_pass
        );
        if ($mesg->is_error()) {
            OpenXPKI::Exception->throw(
                message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_CRLISSUANCE_PUBLISHCRL_LDAP_BIND_FAILED',
                params  => {
                    ERROR      => $mesg->error(),
                    ERROR_DESC => $mesg->error_desc(),
                }
            );
        }
        ##! 2: 'ldap->bind() done'
    
        $mesg = $ldap->search(base      => $ldap_base_dn,
                              filter    => "($ldap_search_dn)",
        );
        if ($mesg->is_error()) {
            OpenXPKI::Exception->throw(
                message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_CRLISSUANCE_PUBLISHCRL_LDAP_SEARCH_FAILED',
                params  => {
                    ERROR      => $mesg->error(),
                    ERROR_DESC => $mesg->error_desc(),
                }
            );
        }
        ##! 2: 'ldap->search() done'
        ##! 16: 'mesg->count: ' . $mesg->count

        if ($mesg->count == 0) {
            OpenXPKI::Exception->throw(
                message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_CRLISSUANCE_PUBLISHCRL_LDAP_ENTRY_NOT_FOUND',
            );
        }
        elsif ($mesg->count > 1) {
            OpenXPKI::Exception->throw(
                message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_CRLISSUANCE_PUBLISHCRL_MORE_THAN_ONE_LDAP_ENTRY_FOUND',
            );
        }
        my $tm = CTX('crypto_layer');
        my $default_token = $tm->get_token(
            TYPE      => 'DEFAULT',
            PKI_REALM => $pki_realm,
        );
        my $crl_der = $default_token->command({
            COMMAND => 'convert_crl',
            DATA    => $crl,
            OUT     => 'DER',
        });
        foreach my $entry ($mesg->entries) {
            ##! 32: 'foreach entry'
            my $mesg = $ldap->modify($entry,
                replace => {
                    'certificateRevocationList;binary' => $crl_der,
                }
            );
            if ($mesg->is_error()) {
                OpenXPKI::Exception->throw(
                    message => 'I18N_OPENXPKI_SERVER_WORKFLOW_ACTIVITY_CRLISSUANCE_PUBLISHCRL_LDAP_MODIFY_FAILED',
                    params  => {
                        ERROR      => $mesg->error(),
                        ERROR_DESC => $mesg->error_desc(),
                    },
                );
            }
        }
    }

    # set publication_date in CRL DB
    my $date = DateTime->now();
    $dbi->update(
        TABLE => 'CRL',
        DATA  => {
            'PUBLICATION_DATE' => $date->epoch(),
        },
        WHERE => {
            'CRL_SERIAL' => $crl_db->{'CRL_SERIAL'},
        },
    );
    $dbi->commit();

    return 1;
}

1;
__END__

=head1 Name

OpenXPKI::Server::Workflow::Activity::CRLIssuance::PublishCRL

=head1 Description

This activity publishes the CRL to the filesystem (defined in the
crl_publication section in config.xml) and sets the publication date
in the CRL database.
