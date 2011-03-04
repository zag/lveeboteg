#!/usr/bin/perl
#===============================================================================
#         FILE:  twifrf.pl
#  DESCRIPTION:  command line tool for sync friendfeed group with twitter account
#       AUTHOR:  Aliaksandr P. Zahatski (Mn), <zag@cpan.org>
#===============================================================================

use Flow;
package Utils;
use strict;
use warnings;
use JSON;

#=head2 fetch_frf $frf_url
#
#return  hashref to data
#
#=cut
sub fetch_frf {
    my $url = shift || return {};
    my $ua = LWP::UserAgent->new;
    $ua->agent("MyApp/0.1 ");
    my $response = $ua->get($url);
    my $res      = [];
    if ( $response->is_success ) {
        $res = decode_json( $response->content );
    }

    else {
        warn $response->status_line . " for $url ";
        return;
    }
    $res;
}

sub get_frf_admins {
    my $group                = shift || return {};
    my $frf_fetch_group_info = "http://friendfeed-api.com/v2/feedinfo/$group";
    my %admins               = ();
    my $adm                  = Utils::fetch_frf($frf_fetch_group_info)
      || die "Error fetch group entries";
    if ( my $rec = $adm->{admins} ) {

        #make map admin_id->name
        foreach (@$rec) { $admins{ $_->{id} } = $_->{name} }
    }
    \%admins;
}

#=========================
#
#    new GetFrF group=>"Group name"
#
package GetFrF;
use strict;
use warnings;
use base 'Flow';
use Data::Dumper;
use constant {

    FRF_POST_ADMIN       => 1,    # publish admins notes
    FRF_POST_ADMIN_LIKED => 1,    # publish notes with admin likes
    FRF_POST_USERS => [ 'lvee', 'lveeboteg' ],    # publish users posts. Change this !!!
    FRF_SKIP_TWITTER_SRC => 1    # skip all twitters imported items

};

sub begin {
    my $self = shift;

    #get admins of group
    $self->{admins} = Utils::get_frf_admins( $self->{group} );
}

sub flow {
    my $self = shift;

    #fetch and grep entries
    my $frf_fetch_url =
        "http://friendfeed-api.com/v2/feed/"
      . $self->{group}
      . '?pretty=1&num=60';
    my $ans_e = Utils::fetch_frf($frf_fetch_url)
      || die "Error fetch group entries";
    my $admins     = $self->{admins};
    my $post_users = FRF_POST_USERS;
    my %h_users;
    @h_users{ @{$post_users} } = ();

    #now filter only messages or posts
    my @assepted = ();
    if ( my $ent = $ans_e->{entries} ) {
        for my $e (@$ent) {
            my $owner = $e->{from}->{id};

            #is owner of entry in admins ?
            if ( FRF_POST_ADMIN && exists( $admins->{$owner} ) ) {

                #$self->put_flow($e);
                push @assepted, $e;
                next;
            }
            if ( exists( $h_users{$owner} ) ) {

                #$self->put_flow($e);
                push @assepted, $e;
                next;
            }

            #if admin like this entry
            if ( FRF_POST_ADMIN_LIKED and my $likes = $e->{likes} ) {
                foreach my $l (@$likes) {
                    my $from = $l->{from}->{id};
                    next unless exists( $admins->{$from} );

                    #$self->put_flow($e);
                    push @assepted, $e;
                    last;    #foreach my $l
                }

            }
        }
    }
    if (FRF_SKIP_TWITTER_SRC) {
        @assepted =
          grep { !( exists $_->{via} && $_->{via}->{name} =~ /Twitter/i ); }
          @assepted;
    }
    return \@assepted;
}

sub end { [] }

package GetTwi;
use strict;
use warnings;
use Net::Twitter;
use base 'Flow';

sub flow {
    my $self = shift;
    my $nt   = $self->{nt};
    my $result = eval { $nt->user_timeline( { count => 30 } ) };
    return $@ if $@;
    $self->put_flow(@$result);
    undef;
}
1;

#=======================
#
#   new SyncEntry::
#
package SyncEntry;
use strict;
use MIME::Base64 qw/encode_base64/;
use HTTP::Request::Common;
use warnings;
use Data::Dumper;
use base 'Flow';
use HTML::Parser;    #(libhtml-parser-perl)

#===========
# post uri, [params]
#
sub post_frf {
    my $self = shift;
    my $ua   = LWP::UserAgent->new();
    $ua->agent("MyApp/0.1 ");
    my $r = POST(@_);
    $r->header( Authorization => 'Basic '
          . encode_base64( $self->{frf_usr} . ':' . $self->{frf_key} ) );
    my $response = $ua->request($r);
    my $res      = [];
    if ( $response->is_success ) {
        $res = decode_json( $response->content );
    }

    else {
        warn $response->status_line . " for " . $_[0];
        return;
    }

}

#=======
# strip_tags ( text, clean_a => 1)
#  clean_a  = 1 remove all tags
#clean_a = 0 replace <a> to href value
sub strip_tags {
    my $self = shift;
    my $text = shift;
    my %args = @_;

    #clean txt
    my $message = '';
    our $INTAG;
    my $p = HTML::Parser->new(
        api_version => 3,
        start_h     => [
            sub {
                my $s = shift;
                my ( $tag, %attr ) = @{ shift @_ };
                $INTAG++;
                if ( $tag eq 'a' ) {
                    $attr{href} =~ s/['"]+//g;

                    #predict if this hash tag
                    unless ( $attr{href} =~
                        m/http:\/\/friendfeed.com\/search\?q=\%23/ )
                    {
                        $message .= $attr{href} unless $args{clean_a};
                    }
                }
            },
            "self,tokens"
        ],
        end_h => [
            sub {
                my $s = shift;
                my ( $tag, %attr ) = @{ shift @_ };
                $INTAG-- if $INTAG;
            },
            "self,tokens"
        ],
        text_h => [
            sub {
                my $txt = join "", @_;

                #dont clean hash tags
                $message .= "$txt " if ( !$INTAG || $txt =~ /\#/ );
            },
            "dtext"
        ],
    );
    $p->parse($text);
    $p->eof;    #!!! for flush texts
    $message;
}

#=============
# shorten_frf_message ( $e, link_to_frf =>1)
#
#
sub shorten_frf_message {
    my $self = shift;
    my $e    = shift;
    my %args = @_;
    my $text = $e->{text};
    my $res  = $self->post_frf( "http://friendfeed-api.com/v2/short",
        [ entry => $e->{entry}->{id} ] );
    $res = $res->{shortUrl} if $res;
    my $short_url = $res || die "Can't get shorten";
    my $out_txt = $short_url;

    if ( $e->{entry}->{thumbnails} ) {
        $out_txt = " [pic]$out_txt";
    }
    if ( length( $e->{text} . $out_txt ) > 140 ) {
        $out_txt = "...$out_txt";
    }
    elsif ( $args{link_to_frf} ) {
        $out_txt = "$out_txt";
    }
    my $message = substr( $text, 0, ( 139 - length($out_txt) ) ) . $out_txt;
    return $message;
}

sub post_to_twi {
    my $self       = shift;
    my $e          = shift;
    my $have_thums = $e->{entry}->{thumbnails} ? 1 : 0;
    my $text       = $e->{text};

    #if exists images always link to friend feed
    my $link_to_frf = 0;
    if ($have_thums) {
        $text = $self->strip_tags( $e->{text}, clean_a => 1 );
        $link_to_frf = 1;
    }
    else {

        #try post with link
        $text = $self->strip_tags( $e->{text}, clean_a => 0 );
        if ( length($text) > 140 ) {
            $text = $self->strip_tags( $e->{text}, clean_a => 1 );
            $link_to_frf++;
        }

    }

    $e->{text} = $text;
    $text = $self->shorten_frf_message( $e, link_to_frf => $link_to_frf )
      if ( length( $e->{text} ) > 140 || $have_thums || $link_to_frf );
    my $nt = $self->{twi_nt};
    my $result = eval { $nt->update( { status => $text } ) };
    if ($@) {

        #$self->put_flow{} if $@ ~= /dublicate/;;
        return { id => "DUBLICATE" } if $@ =~ /duplicate/;
        warn "$@\n";
        return;
    }
    $result;
}

sub post_to_frf {
    my $self   = shift;
    my $e      = shift;
    my $posted = $self->post_frf( "http://friendfeed-api.com/v2/entry",
        [ body => $e->{text}, to => $self->{frf_group} ] );

    #post_frf
    $posted;
}

sub flow {
    my $self = shift;
    foreach my $e (@_) {
        my $posted_sid;
        if ( $e->{src} eq 'frf' ) {
            warn "post to twi:" . $e->{guid};
            if ( my $twi_post = $self->post_to_twi($e) ) {
                $self->put_flow( $e, { guid => "twi:" . $twi_post->{id} } );
            }

        }
        elsif ( $e->{src} eq 'twi' ) {
            warn "post to frf:" . $e->{guid};
            if ( my $frf_post = $self->post_to_frf($e) ) {
                $self->put_flow( $e, { guid => "frf:" . $frf_post->{id} } );
            }

        }
        else {
            warn "Unknown source" . $e->{src};
        }
    }
}
1;
use strict;
use warnings;
use Net::Twitter;
use Data::Dumper;
use JSON;
use Test::More;
use LWP::UserAgent;
use Getopt::Long;
use Pod::Usage;
use XML::Flow qw( ref2xml xml2ref);
use Flow;
use constant {

    TWI_CONSUMER_KEY    => '', #set it
    TWI_CONSUMER_SECRET => '', #set it
    TWI_ACCESS_TOKEN    => '', #set it
    TWI_ACCESS_TOKEN_SECRET => '', #set it
    FRF_GROUP               => '', #set it
    FRF_USR                 => '', #set it
    FRF_RKEY                => ''  #set it
};

sub commit {
    my ( $filename, $ref ) = (@_);
    open FH, ">$filename";
    my $flow = ( new XML::Flow:: \*FH );
    $flow->startTag("XML-FLow-Data");
    $flow->write($ref);
    $flow->endTag("XML-FLow-Data");
    close FH;

}

#parse opt
my ( $help, $man, $init, $fromfrf, $fromtwi, $file );

my %opt = (
    help    => \$help,
    man     => \$man,
    init    => \$init,
    fromfrf => \$fromfrf,
    fromtwi => \$fromtwi,
    file    => \$file
);
GetOptions( \%opt, 'help|?', 'man', 'init|i', "fromtwi|twi", "fromfrf|frf",
    "file|f=s" )
  or pod2usage(2);
pod2usage(1) if $help;
pod2usage( -exitstatus => 0, -verbose => 2 ) if $man;
my $db       = {};
my $filename = $file;

if ($init) {
    diag "Init data base $filename";
    commit( $filename, $db );
}
if ($filename) {
    pod2usage(
        -exitstatus => 2,
        -message    => "Not exists database file  [-f] : $filename"
    ) unless -e $filename;

    #load all items to mem
    my $loaded = {};
    open FH, "<$filename" or die "ERR: open $filename:" . $!;
    eval { $loaded = xml2ref( \*FH ); };
    unless ($@) {
        $db = $loaded;
    }
    else {
        warn "ERR:load db: " . $@;
    }
    close FH;
}
else {
    pod2usage( -exitstatus => 2, -message => 'Need db file [-f] !' );
}

#save db;
my $frf = create_flow(
    GetFrF => { group => FRF_GROUP },
    sub {
        [
            map {
                {
                    src   => 'frf',
                    sid   => $_->{id},
                    guid  => "frf:" . $_->{id},
                    entry => $_,
                    text  => $_->{body}
                }
              } @_
        ];
    },
);

my $nt = Net::Twitter->new(
    traits              => [qw/OAuth API::REST/],
    consumer_key        => TWI_CONSUMER_KEY,
    consumer_secret     => TWI_CONSUMER_SECRET,
    access_token        => TWI_ACCESS_TOKEN,
    access_token_secret => TWI_ACCESS_TOKEN_SECRET,
);

my $twi = create_flow(
    GetTwi => {
        nt => $nt
    },
    sub {
        [
            map {
                {
                    src   => 'twi',
                    sid   => $_->{id},
                    guid  => "twi:" . $_->{id},
                    entry => $_,
                    text  => $_->{text},
                }
              } @_
        ];
    },
);
my @join_args = ();

#set all sources unless limited by shell params
#unless ( $fromfrf || $fromtwi ) {
#    $fromfrf = $fromtwi = 1;
#}

if ($fromfrf) {
    push @join_args, Frf => $frf;
}
if ($fromtwi) {
    push @join_args, Twi => $twi;
}

my $j = new Flow::Join:: @join_args;

my $post_object = $init ? new Flow:: : new SyncEntry::

  twi_nt    => $nt,
  frf_usr   => FRF_USR,
  frf_key   => FRF_RKEY,
  frf_group => FRF_GROUP;

my $main_flow = create_flow(
    $j,
    sub {    #skip if in db
        [ grep { !exists $db->{ $_->{guid} } } @_ ];
    },
    Splice => 10,
    $post_object,    #post and return posted ids
                     #Mark as already posted
    sub { $db->{ $_->{guid} }++ for @_; \@_ }
);
$main_flow->run;
commit( $filename, $db );

=head1 NAME

  twifrf.pl  - command line tool for sync friendfeed group with twitter account

=head1 SYNOPSIS

  #init db
  twifrf.pl -init -twi -frf -f storage.xml

  # do sync
  ./twifrf.pl -twi -frf -f storage.xml

  #publish new messages only from friendfeed
  ./twifrf.pl -frf -f storage.xml

   options:

    -help  - print help message
    -man   - print man page
    -init,-i -init database for messages ( combine with -totwi, -tofrf)
    -fromfrf,-frf - stream messages from friendfeed group to twitter
    -fromtwi,-twi - stream messages from twitter to friendfeed group
    -file, -f - database file, used for store

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits

=item B<-man>

Prints manual page and exits

=item B<-init>,B<-i>

init database

=back

=head1 DESCRIPTION

  B<twifrf>  - command line tool for sync friendfeed group with twitter account

=head1 AUTHOR

Zahatski Aliaksandr, E<lt>zahatski@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2010-2011 by Zahatski Aliaksandr

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

