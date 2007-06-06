#!/usr/bin/perl

use Linux::Inotify2;
use FindBin;
use File::Find;
use File::Spec;
use Cwd qw(realpath);

use lib ("$FindBin::Bin/perl5lib", "$FindBin::Bin/perl5lib/3rdparty");

use OneTeam::Builder::Bundle;
use OneTeam::Utils;

my %args = @ARGV;

my $i = new Linux::Inotify2;
$i->blocking(0);

sub watch_path{
    my $path = shift;
    $i->watch($path, -d $path ?
              IN_MOVED_TO|IN_CREATE :
              IN_MODIFY|IN_DELETE_SELF|IN_MOVE_SELF);
}

my $topdir = realpath(File::Spec->catdir($FindBin::Bin, ".."));
my $dir = realpath(File::Spec->catdir($topdir, qw(chrome oneteam)));

find(sub { watch_path($File::Find::name) },$dir);

my %defs = ( REVISION => \&get_revision,
             DEBUG => 1,
             NOJAR => 1);

@filters = (
    new OneTeam::Builder::Filter::Preprocessor(%defs),
    new OneTeam::Builder::Filter::LocaleProcessor::Web(1, split /,/, ($args{LANGS}||"")),
    new OneTeam::Builder::Filter::PathConverter::Web(),
    new OneTeam::Builder::Filter::DialogSizeProcessor(),
    new OneTeam::Builder::Filter::Saver::WebDir($topdir)
);

my @all_files;
my $locale = ($filters[1]->locales)[0];

find(sub {
        push @all_files, $File::Find::name
            if -f and not $File::Find::dir =~ m!(^|[/\\]).svn([/\\]|$)!;
    }, $dir);

for my $file (@all_files) {
    my $content = slurp($file);

    $content = $_->analyze($content, File::Spec->abs2rel($file, $dir))
        for @filters;
}

my %changed_files;
while (1) {
    my @e = $i->read();
    for (@e) {
        my $fn = File::Spec->abs2rel($_->fullname, $topdir);
        next if $fn =~ /(\.swp|~)$/ or $fn =~ /\/\.#/;

        print "UP: $fn\n";
        watch_path($_->fullname)
            if $_->mask & (IN_MOVED_TO|IN_CREATE);
        $changed_files{$fn} = 1
            if $_->mask & (IN_MOVED_TO|IN_CREATE|IN_MODIFY);
        $_->w->cancel
            if $_->mask & (IN_DELETE_SELF|IN_MOVE_SELF);
    }

    if (@e or not %changed_files) {
        sleep 1;
        next;
    }

    print "UPDATE: ",join(", ", keys %changed_files), "\n";
    for my $file (keys %changed_files) {
        eval {
            $file = File::Spec->rel2abs($file, $topdir);

            my $input = slurp($file);
            my $input2 = $input;

            $input2 = $_->analyze($input2, File::Spec->abs2rel($file, $dir))
                for @filters;

            $input = $_->process($input, File::Spec->abs2rel($file, $dir), $locale)
                for @filters;
        };
        print "ERROR: $@" if $@;
    }

    %changed_files = ();
}
