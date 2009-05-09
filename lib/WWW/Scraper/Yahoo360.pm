#
# Ignorant Yahoo 360 blog scraper (blog.360.yahoo.com)
#
# $Id$

package WWW::Scraper::Yahoo360;

use strict;
use warnings;

use Carp           ();
use Date::Parse    ();
use File::Slurp    ();
use HTTP::Date     ();
use JSON::XS       ();
use WWW::Mechanize ();

use constant BLOG_URL   => q{http://blog.360.yahoo.com/blog/};
use constant LOGIN_FORM => q{login_form};
use constant LOGIN_URL  => q{https://login.yahoo.com/config/login_verify2?.intl=us&.done=http%3A%2F%2Fblog.360.yahoo.com%2Fblog%2F%3F.login%3D1&.src=360};

our $VERSION = '0.03';

sub new {
    my ($class, $args) = @_;
    $class = ref $class || $class || __PACKAGE__;
    my $self = $args;
    bless $self, $class;
}

# Fetches high-level blog information
sub blog_info {
    my ($self, $blog_page) = @_;

    if (! $blog_page) {
        $blog_page = $self->blog_main_page();
    }

    # Get sharing level
    #
    # <p class="footnote">Your blog can be seen by  <strong>Public</strong>
    #
    my $sharing = q{};
    if ($blog_page =~ m{Your blog can be seen by  <strong>([\w\s]+)</strong>}m) {
        $sharing = lc $1; 
    }

    # Get title
    my $title = q{};
    if ($blog_page =~ m{<h3>([^<]+)<span class="view-toggle">Full Post View}m) {
        $title = $1;
    }

    # Get number of posts
    #
    # <span><em>1 - 5</em> of <em class="limit">13</em> ...
    my $start =
    my $end   =
    my $count = 0;

    if ($blog_page =~ m{<span><em>(\d+) \- (\d+)</em> of <em class="limit">(\d+)</em>}m) {
        $start = $1;
        $end   = $2;
        $count = $3;
    }

    my $link = q{};
    if ($blog_page =~ m{<a href="([^"]+)" class="selected">My Blog</a>}) {
        $link = $1;
    }

    $title =~ s{^\s+}{};
    $title =~ s{\s+$}{};

    return {
        sharing => $sharing,
        title   => $title,
        start   => $start,
        end     => $end,
        count   => $count,
        link    => $link,
        lastBuildDate => HTTP::Date::time2str(),
        language => 'en-us',
    };

}

# Fetches the user's main blog page
sub blog_main_page {
    my ($self) = @_;
    my $mech = $self->mech();
    $mech->get(BLOG_URL);
    if ($mech->success()) {
        return $mech->content();
    }
    Carp::croak("Failed to retrieve blog main page");
}

# Builds the url to fetch a specific blog page
sub blog_page_url {
    my ($self, $link, $start, $per_page, $count) = @_;
    my $url = $link;
    my $last = $start + $per_page - 1;
    if ($last > $count) { $last = $count }
    $url .= '&l=' . $start;
    $url .= '&u=' . $last;
    $url .= '&mx=' . $count;
    $url .= '&lmt=' . $per_page;
    return $url;
}

# Logs in to Yahoo
sub login {
    my ($self) = @_;

    my $user = $self->{username};
    my $pass = $self->{password};

    my $mech = $self->mech();

    $mech->get(LOGIN_URL);

    $mech->submit_form(
        form_name => LOGIN_FORM,
        fields    => {
            login => $user,
            passwd => $pass,
            '.persistent' => 'y',
        }, 
        button    => '.save',
    );

    return $mech->success();
}

# Dumps last accessed page content to STDOUT
sub dump {
    my ($self) = @_;
    print $self->mech->content();
}

# Retrieves all comments in the user's blog
sub get_blog_comments {
    my ($self, $posts) = @_;

    if (! $posts) {
        return;
    }

    my @comments;

    for my $post (@{$posts}) {

        # No comments, don't fetch them
        if ($post->{comments} == 0) {
            next;
        }

        #print qq{Found $post->{comments} comments for blog post "$post->{title}"\n};

        if (my $post_comm = $self->get_blogpost_comments($post)) {
            push @comments, @{ $post_comm };
        }

    }

    return \@comments;
}

# Retrieves all comments to a single blog post
sub get_blogpost_comments {
    my ($self, $post, $page) = @_;

    # If we didn't get a pre-saved html page, get it now
    if (! $page) {
        $self->mech->get($post->{link});
        $page = $self->mech->success
            ? $self->mech->content()
            : q{};
    }

    if (! $page) {
        warn "ERROR fetching blogpost comments for $post->{title}\n";
        return;
    }

    my @comments;

    while ($page =~ m{<li class="user-name"><a href="([^"]+)" title="([^"]+)">}mg) {

        my $comment = {
            'user-profile' => $1,
            username => $2,
            link => $post->{link},
        };

        # Comments can span multiple lines
        # but are always enclosed between <p class="comment"> and </p>
        if ($page =~ m{<p class="comment">(.*?)</p>}sg) {
            $comment->{comment} = $1;
            $comment->{comment} =~ s{^\s+}{};
            $comment->{comment} =~ s{\s+$}{};
        }

        if ($page =~ m{<p class="datestamp">([^<]+)\s*<}mg) {
            $comment->{date} = $1;
            $comment->{date} =~ s{^\s+}{};
            $comment->{date} =~ s{\s+$}{};
            $comment->{date} = $self->parse_date($comment->{date});
        }

        push @comments, $comment;
    }

    return \@comments;
}

# Gets all blog posts by a user
sub get_blog_posts {
    my ($self, $blog_page, %overrides) = @_;

    $blog_page ||= $self->blog_main_page();
    my $blog_info = $self->blog_info($blog_page);

    for (keys %overrides) {
        $blog_info->{$_} = $overrides{$_};
    }

    my $link  = $blog_info->{link};
    my $start = $blog_info->{start};
    my $end   = $blog_info->{end};
    my $count = $blog_info->{count};
    my $per_page = $end - $start + 1;

    my @posts = ();

    for (my $n = $start; $n < $start + $count; ) {

        #print "Reading post n. $n\n";

        # Fetch next page and continue
        if ($n >= $end) {

            my $next_page_url = $self->blog_page_url(
                $link, $end + 1, $per_page, $count
            );

            $end += $per_page;

            $self->mech->get($next_page_url);
            #warn "Next url is: $next_page_url\n";

            $blog_page = $self->mech->content();
            if (! $blog_page) {
                warn "Failed to read url: $next_page_url\n";
                last;
            }

        }

        while ($blog_page =~ m{<dt class="post-head">([^<]+)</dt>}gm) {
           
            # Blog post title 
            my $title = $1;
            my $post = { title => $1 };

            #print "    [$n] Title: $title\n";

            # Blog post content
            if ($blog_page =~ m{<div class="content-wrapper">(.*?)</div>}gm) {
                $post->{description} = $1;
                #print "    [$n] Body: ", substr($1, 0, 30), '... ', "\n";
            }

            # Tags
            if ($blog_page =~ m{<form><input type="hidden" name="tagslist" value="([^"]*)"}gm) {
                $post->{tags} = $1;
                #print "    [$n] Tags: $1\n";
            }

            # Date of post
            if ($blog_page =~ m{<span>([^<]+)<a href="[^"]+">Edit</a>}gm) {
                $post->{pubDate} = HTTP::Date::time2str($self->parse_date($1));
                #print "    [$n] Date: $1\n";
            }

            # Permanent link
            if ($blog_page =~ m{<a href="([^"]+)">Permanent Link</a>}gm) {
                $post->{link} = $1;
                #print "    [$n] Permalink: $1\n";
            }

            # No. of comments
            if ($blog_page =~ m{<a href="[^"]+">(\d+) Comments?</a>}gm) {
                $post->{comments} = $1;
            }

            push @posts, $post;

            $n++;

        }

    }

    return \@posts;

}

# Mechanize object accessor
sub mech {
    my ($self) = @_;
    if (! exists $self->{_mech}) {
        $self->{_mech} = WWW::Mechanize->new();
    }
    return $self->{_mech};
}

# Tries to parse a date in the Yahoo 360 format
sub parse_date {
    my ($self, $date) = @_;

    $date =~ s{^\s+}{};
    $date =~ s{\s+$}{};

    if ($date =~ m{^ (\w{3})\w+ \s (\w{3})\w+ \s (\d+), \s (\d+) \s - \s (\d+):(\d+)([ap]m) \s \((.*)\) \s* $}x) {
        my $dow   = $1;
        my $month = $2;
        my $day   = $3;
        my $year  = $4;
        my $hours = $5;
        my $mins  = $6;
        my $ampm  = uc $7;
        my $tz    = uc $8;

        # Indochina time zone is not recognized by Date::Parse
        if ($tz eq 'ICT') {
            $tz = 'UTC+07';
        }

        if ($ampm eq 'pm') {
            $hours += 12;
            if ($hours > 23) { $hours -= 24 }
        }

        my $time = "$hours:$mins:00";

        # Wed, 16 Jun 94 07:29:35 CST
        $date = "$day $month $year $time $tz"; 
    }

    $date = Date::Parse::str2time($date);

    return $date;
}

1;

__END__

=head1 NAME

WWW::Scraper::Yahoo360 - Yahoo 360 blogs old-fashioned crappy scraper

=head1 SYNOPSIS

  use WWW::Scraper::Yahoo360;

  my $y360 = WWW::Scraper::Yahoo360->new({
      username => 'myusername',
      password => 'mypassword',
  });

  # First you have to login
  $y360->login() or die "Login failed?";

  # High level blog information
  my $blog_info = $y360->blog_info();

  # Gets all the blog posts
  my $posts     = $y360->get_blog_posts();

  # Gets all the blog post comments
  my $comments  = $y360->get_blog_comments();

=head1 DESCRIPTION

Ignorant web scraper, based on WWW::Mechanize, that connects to your
Yahoo 360 account and tries to fetch the blog posts and comments 
you still have on their service.

If it breaks, well... it's a scraper.

This module is used on the My Opera Community, L<http://my.opera.com>,
to import Yahoo 360 existing blogs into My Opera blog service.

=head1 SUBROUTINES

=head2 C<new(\%args)>

Where C<\%args> is a hashref with C<username> and C<password> of your
B<Yahoo 360> account.

This creates a new C<WWW::Scraper::Yahoo360> object, ready to scrape.

=head2 C<blog_info([$blog_page])>

Fetches high-level blog information for your Yahoo 360 blog.
If a C<$blog_page> argument is supplied, the blog information is
looked up inside the contents of that scalar. Otherwise it's fetched
from the network. C<$blog_page> must contain a full HTML page string.

Returns a hashref with the some/all the following information:
    
=over 4

=item C<link>

Something like: C<<< http://blog.360.yahoo.com/blog-<yourusername> >>>

=item C<sharing>

Most probably C<public>. Could also be C<friends> or C<friends of friends>,
but never tried it.

=item C<count>

Number of blog posts in total.

=item C<start>

First blog post on the frontpage. Should be 1.

=item C<end>

Last blog post on the frontpage, usually 5.

=item C<title>

Title of the blog.

=back

=head2 C<blog_main_page()>

Fetches the user's main blog page.
Returns a string with the HTML page contents.
This can be used in C<blog_info()> or C<get_blog_posts()>.

=head2 C<blog_page_url($link, $start, $per_page, $count)>

Builds the url to fetch a specific blog page.

=head2 C<dump()>

Dumps last accessed page content to STDOUT

=head2 C<login()>

Logs in to Yahoo service.
Returns a scalar that tells you if the login was successful or not.

=head2 C<get_blog_comments(\@posts)>

Retrieves all comments in the user's blog.
Wants the structure returned by C<get_blog_posts()>.

=head2 C<get_blogpost_comments($post)>

Retrieves all comments to a single blog post.
Wants a single C<$post> entry (hashref): one of the elements
returned by C<get_blog_posts()>.

=head2 C<get_blog_posts([$blog_page, [%overrides]])>

Gets all blog posts by a user. If C<$blog_page> is supplied, it looks
for blog posts in that page only.

C<%overrides> can be a set passed to override some of the properties
about the blog to be scraped and parsed. To see the list of properties,
look at C<blog_info()>.

Returns an array of hashrefs, each one representing a blog post.
Each post (hashref) should have the following keys:

Example:

	$y360 = WWW::Scraper::Yahoo360->new({
		username => '...'
		password => '...',
	});

	$y360->login() or die "Failed login";

	# Fetch only the first blog post, no matter what
	my $first_page = $y360->blog_main_page();
	my $blog_posts = $y360->get_blog_posts($first_page, count=>1);

=over 4

=item C<comments>

Number of comments to this blog post

=item C<description>

Blog post content

=item C<link>

Permanent URL of the blog post

=item C<pubDate>

Date when the blog post was published, in C<HTTP::Date> format,
ex.: C<Sun, Nov 14 06:20:28 CET>.

=item C<tags>

Comma delimited string of tags (ex.: C<travel, holiday>)

=item C<title>

Title of the blog post

=back

=head2 C<mech()>

C<WWW::Mechanize> object accessor.

=head2 C<parse_date($date_string)>

Tries to parse a date from the Yahoo 360 format to a unix timestamp.

=head1 EXPORTS

None by default.

=head1 AUTHOR

Cosimo Streppone, E<lt>cosimo@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Cosimo Streppone, L<cosimo@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

