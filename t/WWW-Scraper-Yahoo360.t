# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl WWW-Scraper-Yahoo360.t'

#########################

use Test::More tests => 25;

BEGIN {
    use_ok('WWW::Scraper::Yahoo360')
}

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $y360 = WWW::Scraper::Yahoo360->new({
    username => 'fake',
    password => 'even-more-fake',
});


# ---------------------------------------------------
# Parsing of blog posts and comments
# ---------------------------------------------------

my $blog_page = File::Slurp::read_file(q{./t/blog.html});
my $blog_info = $y360->blog_info($blog_page);
#iag( JSON::XS->new->pretty->encode($blog_info) );

is (
    $blog_info->{link},
    'http://blog.360.yahoo.com/blog-jfCUH8k5fqpqLD7PHOY4YMCi5eU-?cq=1',
    'Blog permanent link is correctly extracted'
);

is (
    $blog_info->{sharing},
    'public',
    'Blog sharing level is correctly extracted'
);

is (
    $blog_info->{count}, 13,
    'Blog posts count is correctly extracted'
);

ok(
    $blog_info->{start} == 1 && $blog_info->{end} == 5,
    'Blog posts start/end is correctly extracted'
);

is(
    $blog_info->{title},
    'Dieu Anh&#39;s Blog',
    'Title of the blog is extracted correctly'
);

#
# get_blog_posts() tests
#
my $posts = $y360->get_blog_posts($blog_page, start=>1, end=>2, count=>1);
is(scalar @{$posts}, 5, 'Parsed 5 blog posts in the blog main page');

my $first = $posts->[0];

ok(
	ref $first eq 'HASH',
	'First blog post is a hashref'
);

ok(
	$first->{title},
	'Title is parsed correctly (' . $first->{title} . ')'
);

is(
	$first->{comments}, 0,
	'Number of comments is correct'
);

like(
	$first->{tags},
	qr{^myopera},
	'Tags parsed correctly (' . $first->{tags} . ')'
);

like(
	$first->{description},
	qr{<img src="http://files\.myopera\.com/myfrenchopera/files/sitelanguage\.jpg"/></div>$},
	'Blog post is not truncated'
);

is(
	$first->{pubDate},
	'Tue, 16 Dec 2008 13:11:00 GMT',
	'Blog post date is parsed correctly'
);

like(
	$first->{link},
	qr{^http://blog\.360\.yahoo\.com/},
	'Blog post link contains blog.360.yahoo.com',
);

#
# get_blogpost_comments() tests
#
my $blogpost_page = File::Slurp::read_file(q{./t/blogpost_with_1_comment.html});
my $comments = $y360->get_blogpost_comments(
    {link=>'http://360.yahoo.com/blah'}, # Pretend we have a link
    $blogpost_page
);

#iag( JSON::XS->new->pretty->encode($comments) );

is (ref $comments, 'ARRAY', 'comments extracted in an array ref');
is (@$comments, 1, 'found one comment');

my $comment = $comments->[0];

like (
    $comment->{link}, qr{http://.*360\.yahoo\.com/.*},
    'Found link to the original blog post (' . $comment->{link} . ')',
);

like (
    $comment->{'user-profile'}, qr{http://.*360\.yahoo\.com/.*},
    'Found link of the profile of the user that posted the comment',
);


like (
    $comment->{comment}, qr{^welcome u visit},
    'Found the comment body'
);

is (
    $comment->{username}, q{palbongro},
    'Found correct username'
);

# ---------------------------------------------------
# Parsing of a blog post with many comments
# ---------------------------------------------------

$blogpost_page = File::Slurp::read_file(q{./t/blogpost_with_many_comments.html});
$comments = $y360->get_blogpost_comments({}, $blogpost_page);

#iag( JSON::XS->new->pretty->encode($comments) );

is (ref $comments, 'ARRAY', 'comments extracted in an array ref');
is (@$comments, 5, 'found correct number of comment');

is (
    $comments->[0]->{username}, 'Not gonna get us',
    'Username of first comment is correct. Extraction order is correct.'
);

# ---------------------------------------------------
# Parsing of dates
# ---------------------------------------------------

# Mon, 25 Aug 2008 12:28:00 GMT
my @dates = (
    [ q{Monday August 25, 2008 - 05:28am (PDT)}, 1219667280 ],
    [ q{Tuesday November 11, 2008 - 10:26pm (ICT)}, 1226373960 ],
);

for (@dates) {
    my ($date, $expected_result) = @$_;
    is (
        $y360->parse_date($date),
        $expected_result,
        'Date {' . $date . '} is parsed correctly'
    );
}

