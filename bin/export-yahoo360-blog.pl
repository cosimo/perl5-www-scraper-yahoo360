#!/usr/bin/env perl
#
# Scrape an existing Yahoo 360 blog by supplying
# the username and password.
#
# $Id$

BEGIN { $| = 1 }

use strict;
use warnings;

use Getopt::Long;
use JSON::XS;
use WWW::Scraper::Yahoo360;

GetOptions(
    'username:s' => \my $username,
    'password:s' => \my $password,
);

if (! $username || ! $password) {
    die "$0 --username=... --password=...\n";
}

my $y360 = WWW::Scraper::Yahoo360->new({
    username => $username,
    password => $password,
});

$y360->login() or die "Can't login to Yahoo!";

my $blog_info = $y360->blog_info();

my $posts = $y360->get_blog_posts();
$blog_info->{items} = $posts;

my $comments = $y360->get_blog_comments($posts);
$blog_info->{comments} = $comments;

my $json = JSON::XS->new()->pretty;
print $json->encode($blog_info);

