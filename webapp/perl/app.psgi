use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Torb::Web;
# use Devel::NYTProf;

my $root_dir = File::Basename::dirname(__FILE__);

local $Kossy::XSLATE_CACHE = 2;
local $Kossy::XSLATE_CACHE_DIR = "$root_dir/.xslate_cache";

my $app = Torb::Web->psgi($root_dir);
builder {
    # enable sub {
    #     my $app = shift;
    #     sub {
    #         my $env = shift;
    #         DB::enable_profile("$root_dir/nytprof.out.$$");
    #         my $res = $app->($env);
    #         DB::disable_profile();
    #         return $res;
    #     };
    # };

    enable 'ReverseProxy';
    # enable 'AxsLog',
    #     logger => sub { syswrite(STDERR, $_[0]) },
    #     response_time => 1,
    #     format => (join "\t", qw!taken:%x status:%>s req:%r size:%b!),
    #     format_options => +{
    #         char_handlers => +{
    #             'x' => sub { defined $_[3] ? $_[3] / 1_000_000 : '-' },
    #         },
    #     };
    enable 'Session::Cookie',
        session_key => 'torb_session',
        expires     => 3600,
        secret      => 'tagomoris';
    # enable 'Static::OpenFileCache',
    #      path => qr!^/(?:(?:css|js|img)/|favicon\.ico$)!,
    #      root => $root_dir . '/public',
    #      max  => 100,
    #      expires => 60,
    #      buf_size => 8192;

    $app;
};

