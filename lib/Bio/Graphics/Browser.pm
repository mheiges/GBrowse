package Bio::Graphics::Browser;
# $Id: Browser.pm,v 1.29 2002-07-31 03:06:14 lstein Exp $
# This package provides methods that support the Generic Genome Browser.
# Its main utility for plugin writers is to access the configuration file information

=head1 NAME

Bio::Graphics::Browser -- Utility methods for the Generic Genome Browser

=head1 SYNOPSIS

  $b = Bio::Graphics::Browser->new;
  $b->read_configuration('/path/to/conf/files');

  my @data_sources = $b->sources;
  my $current_source = $b->source;
  my $setting = $b->setting('default width');
  my $description    = $b->description;
  my @track_labels   = $b->labels;
  my @default_tracks = $b->default_labels;
  my $track_label    = $b->feature2label;

  # warning: commas() is exported
  my $big_number_with_commas = commas($big_number_without_commas);

=head1 DESCRIPTION

This package provides methods that support the Generic Genome Browser.
Its main utility for plugin writers is to access the configuration
file information.

Typically, the Bio::Graphics::Browser object will be created before
the plugin is invoked, and will be passed to the plugin for retrieval
by its browser_config method.  For example:

  $browser_obj = $self->browser_config;

Each browser configuration has a set of "sources" that correspond to
the individual configuration files in the gbrowse.conf directory.  At
any time there is a "current source" which indicates the source to
fetch settings from.  It is equal to the current setting of the "Data
Source" menu.

From the current source you can retrieve configuration settings
corresponding to the keys and values of the current config file.
These are fetched using the setting() method.  You can retrieve both
general settings and settings that are specific to a particular
track.

=head1 METHODS

The remainder of this document describes the methods available to the
programmer.

=cut

use strict;
use File::Basename 'basename';
use Bio::Graphics;
use Carp qw(carp croak);
use GD 'gdMediumBoldFont';
use CGI qw(img param escape url);
use Digest::MD5 'md5_hex';
use File::Path 'mkpath';
use Text::Shellwords;

require Exporter;

use vars '$VERSION','@ISA','@EXPORT';
$VERSION = '1.14';

@ISA    = 'Exporter';
@EXPORT = 'commas';

use constant DEFAULT_WIDTH => 800;
use constant RULER_INTERVALS   => 20;  # fineness of the centering map on the ruler
use constant TOO_MANY_SEGMENTS => 5_000;
use constant MAX_SEGMENT       => 1_000_000;
use constant DEFAULT_RANGES       => q(100 500 1000 5000 10000 25000 100000 200000 400000);
use constant MIN_OVERVIEW_PAD  => 20;

use constant DEBUG => 0;

=head2 new()

  my $browser = Bio::Graphics::Browser->new();

Create a new Bio::Graphics::Browser object.  The object is initially
empty.  This is done automatically by gbrowse.

=cut

sub new {
  my $class    = shift;
  my $self = bless { },ref($class) || $class;
  $self;
}

=head2 read_configuration()

  my $success = $browser->read_configuration('/path/to/gbrowse.conf');

Parse the files in the gbrowse.conf configuration directory.  This is
done automatically by gbrowse.  Returns a true status code if
successful.

=cut

sub read_configuration {
  my $self        = shift;
  my $conf_dir    = shift;
  $self->{conf} ||= {};

  croak("$conf_dir: not a directory") unless -d $conf_dir;
  opendir(D,$conf_dir) or croak "Couldn't open $conf_dir: $!";
  my @conf_files = map { "$conf_dir/$_" } grep {/\.conf$/} readdir(D);
  close D;

  # try to work around a bug in Apache/mod_perl which appears when
  # running under linux/glibc 2.2.1
  unless (@conf_files) {
    @conf_files = glob("$conf_dir/*.conf");
  }

  # get modification times
  my %mtimes     = map { $_ => (stat($_))[9] } @conf_files;

  for my $file (sort {$b cmp $a} @conf_files) {
    my $basename = basename($file,'.conf');
    $basename =~ s/^\d+\.//;
    next if defined($self->{conf}{$basename}{mtime})
      && ($self->{conf}{$basename}{mtime} >= $mtimes{$file});
    my $config = Bio::Graphics::BrowserConfig->new(-file => $file,-safe=>1) or next;
    $self->{conf}{$basename}{data}  = $config;
    $self->{conf}{$basename}{mtime} = $mtimes{$file};
    $self->{source} ||= $basename;
  }
  $self->{width} = DEFAULT_WIDTH;
  1;
}

=head2 sources()

  @sources = $browser->sources;

Returns the list of symbolic names for sources.  The symbolic names
are derived from the configuration file name by:

  1) stripping off the .conf extension.
  2) removing the pattern "\d+\."

This means that the configuration file "03.fly.conf" will have the
symbolic name "fly".

=cut

sub sources {
  my $self = shift;
  my $conf = $self->{conf} or return;
  return keys %$conf;
}

=head2 source()

  $source = $browser->source;
  $source = $browser->source($new_source);

Sets or gets the current source.  The default source will the first
one found in the gbrowse.conf directory when sorted alphabetically.

If you attempt to set an invalid source, the module will issue a
warning but will not raise an exception.

=cut

# get/set current source (not sure if this is wanted)
sub source {
  my $self = shift;
  my $d = $self->{source};
  if (@_) {
    my $source = shift;
    unless ($self->{conf}{$source}) {
      carp("invalid source: $source");
      return $d;
    }
    $self->{source} = $source;
  }
  $d;
}

=head2 setting()

  $value = $browser->setting(general => 'stylesheet');
  $value = $browser->setting(gene => 'fgcolor');
  $value = $browser->setting('stylesheet');

The setting() method returns the value of one of the current source's
configuration settings.  setting() takes two arguments.  The first
argument is the name of the stanza in which the configuration option
is located.  The second argument is the name of the setting.  Stanza
and option names are case sensitive, with the exception of the
"general" section, which is automatically folded to lowercase.

If only one argument is provided, then the "general" stanza is
assumed.

Option values are folded in such a way that newlines and tabs become
single spaces.  For example, if the "default features" option is defined like this:

 default features = Transcripts
                    Genes
	 	    Scaffolds

Then the value retrieved by 

  $browser->setting('general'=>'default features');

will be the string "Transcripts Genes Scaffolds".  Note that it is
your responsibility to split this into a list.  I suggest that you use
Text::Shellwords to split the list in such a way that quotes and
escapes are preserved.

Because of the default, you could also fetch this information without
explicitly specifying the stanza.  Combined with shellwords gives the
idiom:

 @defaults = shellwords($browser->setting('default features'));

=cut

sub setting {
  my $self = shift;
  my @args = @_;
  if (@args == 1) {
    unshift @args,'general';
  } else {
    $args[0] = 'general' 
      if $args[0] ne 'general' && lc($args[0]) eq 'general';  # buglet
  }
  $self->config->setting(@args);
}

=head2 dbgff_settings()

  @args = $browser->dbgff_settings;

Returns the appropriate arguments for connecting to Bio::DB::GFF.  It
can be used this way:

  $db = Bio::DB::GFF->new($browser->dbgff_settings);

=cut

# get Bio::DB::GFF settings
sub dbgff_settings {
  my $self = shift;

  my $dsn     = $self->setting('database') or croak "No database defined in ",$self->source;
  my $adaptor = $self->setting('adaptor') || 'dbi::mysqlopt';
  my @argv = (-adaptor => $adaptor,
	      -dsn     => $dsn);
  if (my $fasta = $self->setting('fasta_files')) {
    push @argv,(-fasta=>$fasta);
  }
  if (my $user = $self->setting('user')) {
    push @argv,(-user=>$user);
  }
  if (my $pass = $self->setting('pass')) {
    push @argv,(-pass=>$pass);
  }
  if (my @aggregators = shellwords($self->setting('aggregators'))) {
    my $agg = $self->make_aggregators(@aggregators);
    push @argv,(-aggregator => $agg);
  }
  @argv;
}

=head2 description()

  $description = $browser->description

This is a shortcut method that returns the value of the "description"
option in the general section.  The value returned is a human-readable
description of the data source.

=cut

sub description {
  my $self = shift;
  my $source = shift;
  my $c = $self->{conf}{$source}{data} or return;
  return $c->setting('general','description');
}

=head2 labels()

  @track_labels = $browser->labels

This method returns the names of each of the track stanzas,
hereinafter called "track labels" or simply "labels".  These labels
can be used in subsequent calls as the first argument to setting() in
order to retrieve track-specific options.

=cut

sub labels {
  my $self  = shift;
  my $order = shift;
  my @labels = $self->config->labels;
  if ($order) { # custom order
    return @labels[@$order];
  } else {
    return @labels;
  }
}

=head2 default_labels()

  @default_labels = $browser->default_labels

This method returns the labels for each track that is turned on by
default.

=cut

sub default_labels {
  my $self = shift;
  $self->config->default_labels;
}

=head2 label2type()

  @feature_types = $browser->label2type($label,$lowres);

Given a track label, this method returns a list of the corresponding
sequence feature types in a form that can be passed to Bio::DB::GFF.
The optional $lowres flag can be used to tell label2type() to select a
set of features that are suitable when viewing large sections of the
sequence (it is up to the person who writes the configuration file to
specify this).

=cut

sub label2type {
  my $self = shift;
  $self->config->label2type(@_);
}

=head2 type2label()

  $label = $browser->type2label($type);

Given a feature type, this method translates it into a track label.

=cut

sub type2label {
  my $self = shift;
  $self->config->type2label(@_);
}

=head2 feature2label()

  $label = $browser->feature2label($feature [,$length]);

Given a Bio::DB::GFF::Feature (or anything that implements a type()
method), this method returns the corresponding label.  If an optional
length is provided, the method takes semantic zooming into account.

=cut

sub feature2label {
  my $self = shift;
  my ($feature,$length) = @_;
  return $self->config->feature2label($feature,$length);
}

=head2 citation()

  $citation = $browser->citation($label)

This is a shortcut method that returns the citation for a given track
label.  It simply calls $browser->setting($label=>'citation');

=cut

sub citation {
  my $self = shift;
  my $label = shift;
  $self->config->setting($label=>'citation');
}

=head2 width()

  $width = $browser->width

This is a shortcut method that returns the width of the display in
pixels.

=cut

sub width {
  my $self = shift;
  my $d = $self->{width};
  $self->{width} = shift if @_;
  $d;
}

=head2 header()

  $header = $browser->header;

This is a shortcut method that returns the header HTML for the gbrowse
page.

=cut

sub header {
  my $self = shift;
  my $header = $self->config->code_setting(general => 'header');
  return $header->(@_) if ref $header eq 'CODE';
  return $header;
}

=head2 footer()

  $footer = $browser->footer;

This is a shortcut method that returns the footer HTML for the gbrowse
page.

=cut

sub footer {
  my $self = shift;
  my $footer = $self->config->code_setting(general => 'footer');
  return $footer->(@_) if ref $footer eq 'CODE';
  return $footer;
}

=head2 config()

  $config = $browser->config;

This method returns a Bio::Graphics::FeatureFile object corresponding
to the current source.

=cut

sub config {
  my $self = shift;
  my $source = $self->source;
  $self->{conf}{$source}{data};
}

sub default_label_indexes {
  my $self = shift;
  $self->config->default_label_indexes;
}

=head2 make_link()

  $url = $browser->make_link($feature)

Given a Bio::SeqFeatureI object, turn it into a URL suitable for use
in a hypertext link.

=cut

sub make_link {
  my $self = shift;
  my $feature = shift;
  return $self->config->make_link($feature);
}

=head2 render_html()

  ($image,$image_map) = $browser->render_html(%args);

Render an image and an image map according to the options in %args.
Returns a two-element list.  The first element is a URL that refers to
the image which can be used as the SRC for an <IMG> tag.  The second
is a complete image map, including the <MAP> and </MAP> sections.

The arguments are a series of tag=>value pairs, where tags are:

  Argument            Value

  segment             A Bio::DB::GFF::Segment or
                      Bio::Das::SegmentI object (required).

  tracks              An arrayref containing a series of track
                        labels to render (required).  The order of the labels
                        determines the order of the tracks.

  options             A hashref containing options to apply to
                        each track (optional).  Keys are the track labels
                        and the values are 0=auto, 1=force no bump,
                        2=force bump, 3=force label, 4=expanded bump.

  feature_files       A hashref containing a series of
                        Bio::Graphics::FeatureFile objects to be
                        rendered onto the display (optional).  The keys
                        are labels assigned to the 3d party
                        features.  These labels must apepar in the
                        tracks arrayref in order for render_html() to
                        determine the order in which to render them.

  do_map              This argument is a flag that controls whether or not
                        to generate the image map.  It defaults to false.

  do_centering_map    This argument is a flag that controls whether or not
                        to add elements to the image map so that the user can
                        center the image by clicking on the scale.  It defaults
                        to false, and has no effect unless do_map is also true.

=cut

sub render_html {
  my $self = shift;
  my %args = @_;

  my $segment         = $args{segment};
  my $feature_files   = $args{feature_files};
  my $options         = $args{options};
  my $tracks          = $args{tracks};
  my $do_map          = $args{do_map};
  my $do_centering_map= $args{do_centering_map};
  my $limit           = $args{limit};

  return unless $segment;

  my($image,$map) = $self->image_and_map(segment       => $segment,
					 feature_files => $feature_files,
					 options       => $options,
					 tracks        => $tracks,
					 limit         => $limit,
					);

  my ($width,$height) = $image->getBounds;
  my $url     = $self->generate_image($image);
  my $img     = img({-src=>$url,-align=>'CENTER',-usemap=>'#hmap',-width=>$width,
		     -height=>$height,-border=>0,-name=>'detailedView'});
  my $img_map = $self->make_map($map,$do_centering_map) if $do_map;
  return wantarray ? ($img,$img_map) : join "<br>",$img,$img_map;
}

=head2 generate_image

  ($url,$path) = $browser->generate_image($gd)

Given a GD::Image object, this method calls its png() or gif() methods
(depending on GD version), stores the output into the temporary
directory given by the "tmpimages" option in the configuration file,
and returns a two element list consisting of the URL to the image and
the physical path of the image.

=cut

sub generate_image {
  my $self  = shift;
  my $image = shift;
  my $extension = $image->can('png') ? 'png' : 'gif';
  my $data      = $image->can('png') ? $image->png : $image->gif;
  my $signature = md5_hex($data);
  my ($uri,$path) = $self->tmpdir($self->source.'/img');
  my $url         = sprintf("%s/%s.%s",$uri,$signature,$extension);
  my $imagefile   = sprintf("%s/%s.%s",$path,$signature,$extension);
  open (F,">$imagefile") || die("Can't open image file $imagefile for writing: $!\n");
  print F $image->can('png') ? $image->png : $image->gif;
  close F;
  return $url;
}

sub tmpdir {
  my $self = shift;

  my $path = shift || '';
  my $tmpuri = $self->setting('tmpimages') or die "no tmpimages option defined, can't generate a picture";
  $tmpuri .= "/$path" if $path;
  my $tmpdir;
  if ($ENV{MOD_PERL}) {
    my $r          = Apache->request;
    my $subr       = $r->lookup_uri($tmpuri);
    $tmpdir        = $subr->filename;
    my $path_info  = $subr->path_info;
    $tmpdir       .= $path_info if $path_info;
  } else {
    $tmpdir = "$ENV{DOCUMENT_ROOT}/$tmpuri";
  }
  mkpath($tmpdir,0,0777) unless -d $tmpdir;
  return ($tmpuri,$tmpdir);
}

sub make_map {
  my $self = shift;
  my $boxes = shift;
  my $centering_map = shift;
  my $map = qq(<map name="hmap">\n);

  # use the scale as a centering mechanism
#  my $ruler = shift @$boxes;
#  $map .= $self->make_centering_map($ruler) if $centering_map;

  foreach (@$boxes){
    next unless $_->[0]->can('primary_tag');
    if ($_->[0]->primary_tag eq 'Segment') {
      $map .= $self->make_centering_map($_) if $centering_map;
      next;
    }
    my $href  = $self->make_href($_->[0]) or next;
    my $alt   = $self->make_title($_->[0]);
    $map .= qq(<area shape="RECT" coords="$_->[1],$_->[2],$_->[3],$_->[4]"
	       href="$href" title="$alt">\n);
  }
  $map .= "</map>\n";
  $map;
}

# this creates image map for rulers and scales, where clicking on the scale
# should center the image on the scale.
sub make_centering_map {
  my $self   = shift;
  my $ruler  = shift;

  return if $ruler->[3]-$ruler->[1] == 0;

  my $length = $ruler->[0]->length;
  my $offset = $ruler->[0]->start;
  my $scale  = $length/($ruler->[3]-$ruler->[1]);

  # divide into RULER_INTERVAL intervals
  my $portion = ($ruler->[3]-$ruler->[1])/RULER_INTERVALS;
  my $ref    = $ruler->[0]->ref;
  my $source =  $self->source;
  my $plugin = escape(param('plugin')||'');

  my @lines;
  for my $i (0..RULER_INTERVALS-1) {
    my $x1 = $portion * $i;
    my $x2 = $portion * ($i+1);
    # put the middle of the sequence range into the middle of the picture
    my $middle = $offset + $scale * ($x1+$x2)/2;
    my $start  = int($middle - $length/2);
    my $stop   = int($start  + $length - 1);
    my $url = url(-relative=>1,-path_info=>1);
    $url .= "?ref=$ref;start=$start;stop=$stop;source=$source;nav4=1;plugin=$plugin";
    push @lines,
      qq(<area shape="RECT" COORDS="$x1,$ruler->[2],$x2,$ruler->[4]"
	 href="$url" title="recenter">\n);
  }
  return join '',@lines;
}

sub make_href {
  my $self = shift;
  my $feature = shift;

  if ($feature->can('make_link')) {
    return $feature->make_link;
  } else {
    return $self->make_link($feature);
  }
}

sub make_title {
  my $self    = shift;
  my $feature = shift;
  return $feature->make_title if $feature->can('make_title');
  return $self->config->make_title($feature);
}

# Generate the image and the box list, and return as a two-element list.
# arguments: a key=>value list
#    'segment'       A feature iterator that responds to next_seq() methods
#    'feature_files' A hash of Bio::Graphics::FeatureFile objects containing 3d party features
#    'options'       An hashref of options, where 0=auto, 1=force no bump, 2=force bump, 3=force label
#                       4=force fast bump, 5=force fast bump and label
#    'limit'         Place a limit on the number of features of each type to show.
#    'tracks'        List of named tracks, in the order in which they are to be shown
#    'label_scale'   If true, prints chromosome name next to scale
sub image_and_map {
  my $self    = shift;
  my %config  = @_;

  my $segment       = $config{segment};
  my $feature_files = $config{feature_files} || {};
  my $tracks        = $config{tracks}        || [];
  my $options       = $config{options}       || {};
  my $limit         = $config{limit}         || {};

  # these are natively configured tracks
  my @labels = $self->labels;

  my $width = $self->width;
  my $conf  = $self->config;
  my $max_labels     = $conf->setting(general=>'label density') || 10;
  my $max_bump       = $conf->setting(general=>'bump density')  || 50;
  my $length         = $segment->length;
  my $global_lowres  = $conf->setting(general=>'low res');

  my @feature_types = map { $conf->label2type($_,$length) } @$tracks;

  # Create the tracks that we will need
  my $panel = Bio::Graphics::Panel->new(-segment => $segment,
					-width   => $width,
					-keycolor => 'moccasin',
					-grid => 1,
				       );
  $panel->add_track($segment   => 'arrow',
		    -double => 1,
		    -tick  => 2,
		    -label => $config{label_scale} ? eval{$segment->ref} : 0,
		   );

  my (%tracks,@blank_tracks);

  for (my $i= 0; $i < @$tracks; $i++) {

    my $label = $tracks->[$i];

    # if we don't have a built-in label, then this is a third party annotation
    if (my $ff = $feature_files->{$label}) {
      push @blank_tracks,$i;
      next;
    }

    # if the glyph is the magic "dna" glyph (for backward compatibility), or if the section
    # is marked as being a "global feature", then we apply the glyph to the entire segment
    my $g = $conf->glyph($label);
    if ((defined $g && ($g eq 'dna')) or $conf->setting($label=>'global feature')) {
      $panel->add_track($segment,
			$conf->style($label)
			);
    }

    else {
      my $track = $panel->add_track(-glyph => 'generic',
				    # -key   => $label,
				    $conf->style($label,$length),
				   );
      $tracks{$label}  = $track;
    }

  }

  if (@feature_types) {  # don't do anything unless we have features to fetch!
    my $iterator = $segment->get_seq_stream(-type=>\@feature_types);
    warn "feature types = @feature_types\n" if DEBUG;
    my (%similarity,%feature_count);

    while (my $feature = $iterator->next_seq) {

      my $label = $self->feature2label($feature,$length);
      my $track = $tracks{$label} or next;

      warn "feature = $feature, label = $label, track = $track\n" if DEBUG;

      $feature_count{$label}++;

      # special case to handle paired EST reads
      # WARNING: HARD-CODED RELIANCE ON METHOD NAMES similarity AND alignment.
      if ($feature->method =~ /^(similarity|alignment)$/i) {
	push @{$similarity{$label}},$feature;
	next;
      }
      $track->add_feature($feature);
    }

    # handle the similarities as a special case
    # WARNING: HARD-CODED f/r, p/q, 3/5 PAIR SUFFIXES.
    for my $label (keys %similarity) {
      my $set = $similarity{$label};
      my %pairs;
      for my $a (@$set) {
	(my $base = $a->name) =~ s/\.[frpq35]$//i;
	push @{$pairs{$base}},$a;
      }
      my $track = $tracks{$label};
      foreach (values %pairs) {
	$track->add_group($_);
      }
    }

    # configure the tracks based on their counts
    for my $label (keys %tracks) {
      next unless $feature_count{$label};

      # break encapsulation -- but this is for testing purposes only
      if (exists($limit->{$label}) && $limit->{$label} > 0) {
	my $parts = $tracks{$label}->{parts};
	splice (@$parts,rand(@$parts),1,())
	  while @$parts > $limit->{$label};
	$feature_count{$label} = $limit->{$label} if $limit->{$label} < $feature_count{$label};
	$tracks{$label}->{parts} = $parts;
      }

      $options->{$label} ||= 0;
      my $do_bump  =   $options->{$label} == 0 ? $feature_count{$label} <= $max_bump
	             : $options->{$label} == 1 ? 0
                     : $options->{$label} == 2 ? 1
                     : $options->{$label} == 3 ? 1
                     : $options->{$label} == 4 ? 2
                     : $options->{$label} == 5 ? 2
		     : 0;
      my $do_label =   $options->{$label} == 0 ? $feature_count{$label} <= $max_labels
	             : $options->{$label} == 3 ? 1
	             : $options->{$label} == 5 ? 1
		     : 0;
      $tracks{$label}->configure(-bump  => $do_bump,
				 -label => $do_label,
				 -description => $do_label && $tracks{$label}->option('description'),
				);
      $tracks{$label}->configure(-connector  => 'none') if !$do_bump;
    }
  }

  # add additional features, if any
  my $offset = 0;
  for my $track (@blank_tracks) {
    my $file = $feature_files->{$tracks->[$track]} or next;
    ref $file or next;
    $track += $offset + 1;
    my $name = $file->name;
    my $inserted = $file->render($panel,$track,$options->{$name},$max_bump,$max_labels);
    $offset += $inserted;
  }

  my $gd       = $panel->gd;
  return $gd   unless wantarray;

  my $boxes    = $panel->boxes;
  return ($gd,$boxes);
}

=head2 overview()

  ($gd,$length) = $browser->overview($segment);

This method generates a GD::Image object containing the image data for
the overview panel.  Its argument is a Bio::DB::GFF::Segment (or
Bio::Das::SegmentI) object. It returns a two element list consisting
of the image data and the length of the segment (in bp).

In the configuration file, any section labeled "[something:overview]"
will be added to the overview panel.

=cut

# generate the overview, if requested, and return it as a GD
sub overview {
  my $self = shift;
  my ($partial_segment) = @_;

  my $factory = $partial_segment->factory;
  my $segment = $factory->segment(-class=>$factory->refclass,
				  -name=>$partial_segment->ref);

  my $conf     = $self->config;
  my $width    = $self->width;
  my @tracks   = $self->config->overview_tracks;
  my $pad      = $self->overview_pad(\@tracks);

  my $panel = Bio::Graphics::Panel->new(-segment => $segment,
					-width   => $width,
					-bgcolor => $self->setting('overview bgcolor')
					            || 'wheat',
					-key_style => 'left',
					-pad_left  => $pad,
					-pad_right => MIN_OVERVIEW_PAD,
				       );

  my $units = $self->setting('overview units');
  $panel->add_track($segment,
		    -glyph     => 'arrow',
		    -double    => 1,
		    -label     => "Overview of ".$segment->ref,
		    -labelfont => gdMediumBoldFont,
		    -tick      => 2,
		    $units ? (-units => $units) : (),
		   );

  $self->add_overview_landmarks($panel,$segment,\@tracks,$pad);

  my $gd = $panel->gd;
  my $red = $gd->colorClosest(255,0,0);
  my ($x1,$x2) = $panel->map_pt($partial_segment->start,$partial_segment->end);
  my ($y1,$y2) = (0,$panel->height-1);
  $x2 = $panel->right-1 if $x2 >= $panel->right;
  $gd->rectangle($x1,$y1,$x2,$y2,$red);

  return ($gd,$segment->length);
}

sub add_overview_landmarks {
  my $self = shift;
  my ($panel,$segment,$tracks,$pad) = @_;
  my $conf = $self->config;

  my (@feature_types,%type2track,%track);

  for my $overview_track (@$tracks) {
    my @types = $conf->label2type($overview_track);
    my $track = $panel->add_track(-glyph  => 'generic',
				  -height  => 3,
				  -fgcolor => 'black',
				  -bgcolor => 'black',
				  $conf->style($overview_track),
				 );
    foreach (@types) {
      $type2track{$_} = $overview_track
    }
    $track{$overview_track} = $track;
    push @feature_types,@types;
  }
  my $iterator = $segment->features(-type=>\@feature_types,-iterator=>1,-rare=>1);

  my %count;
  while (my $feature = $iterator->next_seq) {
    my $track_name = $type2track{$feature->type} || $type2track{$feature->method} || next;
    my $track = $track{$track_name} or next;
    $track->add_feature($feature);
    $count{$track_name}++;
  }

  my $max_label  = $conf->setting(general=>'label density') || 10;
  my $max_bump   = $conf->setting(general=>'bump density') || 50;

  for my $track_name (keys %count) {
    my $track = $track{$track_name};
    my $bump  = defined $conf->setting($track_name => 'bump')
              ? $conf->setting($track_name=>'bump')    : $count{$track_name} <= $max_bump;
    my $label = defined $conf->setting($track_name  => 'label')
              ? $conf->setting($track_name => 'label') : $count{$track_name} <= $max_label;
    $track->configure(-bump  => $bump,
		      -label => $label,
		     );
  }
  return \%track;
  $panel;
}

=head2 hits_on_overview()

  $hashref = $browser->hits_on_overview($db,@hits);

This method is used to render a series of genomic positions ("hits")
into a graphical summary of where they hit on the genome in a
segment-by-segment (e.g. chromosome) manner.

The first argument is a Bio::DB::GFF (or Bio::DasI) database.  The
second and subsequent arguments are one of:

  1) a set of array refs in the form [ref,start,stop,name], where
     name is optional.

  2) a Bio::DB::GFF::Feature object

  3) a Bio::SeqFeatureI object.

The returned HTML is stored in a hashref, where the keys are the
reference sequence names and the values are HTML to be emitted.

=cut

# Return an HTML showing where multiple hits fall on the genome.
# Can either provide a list of objects that provide the ref() method call, or
# a list of arrayrefs in the form [ref,start,stop,[name]]
sub hits_on_overview {
  my $self = shift;
  my ($db,$hits) = @_;

  my %html; # results are a hashref sorted by chromosome

  my $conf  = $self->config;
  my $width = $self->width;
  my $units = $self->setting('overview units');
  my $max_label  = $conf->setting(general=>'label density') || 10;
  my $max_bump   = $conf->setting(general=>'bump density') || 50;
  my $class      = $hits->[0]->can('factory') ? $hits->[0]->factory->refclass : 'Sequence';
  my $pad        = $self->overview_pad([$self->config->overview_tracks],'Matches');

  # sort hits out by reference
  my (%refs);
  for my $hit (@$hits) {
    if (ref($hit) eq 'ARRAY') {
      my ($ref,$start,$stop,$name) = @$hit;
      push @{$refs{$ref}},Bio::Graphics::Feature->new(-start=>$start,
						      -stop=>$stop,
						      -name=>$name||'');
    } elsif (UNIVERSAL::can($hit,'ref')) {
      my $ref  = $hit->ref;
      my $name = $hit->can('seqname') ? $hit->seqname : $hit->name;
      my($start,$end) = ($hit->start,$hit->end);
      $name =~ s/\:\d+,\d+$//;  # remove coordinates if they're there
      $name = substr($name,0,7).'...' if length $name > 10;
      push @{$refs{$ref}},Bio::Graphics::Feature->new(-start=>$start,
						      -stop=>$end,
						      -name=>$name);
    } elsif (UNIVERSAL::can($hit,'location')) {
      my $location = $hit->location;
      my ($ref,$start,$stop,$name) = ($location->seq_id,$location->start,
				      $location->end,$location->primary_tag);
      push @{$refs{$ref}},Bio::Graphics::Feature->new(-start=>$start,
						      -stop=>$stop,
						      -name=>$name||'');
    }
  }

  for my $ref (sort keys %refs) {
    my $segment = ($db->segment(-class=>$class,-name=>$ref))[0];
    my $panel = Bio::Graphics::Panel->new(-segment => $segment,
					  -width   => $width,
					  -bgcolor => $self->setting('overview bgcolor')
					  || 'wheat',
					  -pad_left  => $pad,
					  -pad_right => MIN_OVERVIEW_PAD,
					  -key_style => 'left',
					 );

    # add the arrow
    $panel->add_track($segment,
		      -glyph     => 'arrow',
		      -double    => 1,
		      -label     => 0, #"Overview of ".$segment->ref,
		      -labelfont => gdMediumBoldFont,
		      -tick      => 2,
		      $units ? (-units => $units) : (),
		     );

    # add the landmarks
    $self->add_overview_landmarks($panel,$segment,[$self->config->overview_tracks]);

    # add the hits
    $panel->add_track($refs{$ref},
		      -glyph     => 'diamond',
		      -height    => 6,
		      -fgcolor   => 'red',
		      -bgcolor   => 'red',
		      -fallback_to_rectangle => 1,
		      -key       => 'Matches',
		      -bump      => @{$refs{$ref}} <= $max_bump,
		      -label     => @{$refs{$ref}} <= $max_bump,  # deliberate
		     );

    my $gd    = $panel->gd;
    my $boxes = $panel->boxes;
    $html{$ref} = $self->_hits_to_html($ref,$gd,$boxes);
  }
  return \%html;
}

# fetch a list of Segment objects given a name or range
# (this used to be in gbrowse executable itself)
sub name2segments {
  my $self = shift;
  my ($name,$db,$toomany) = @_;
  $toomany ||= TOO_MANY_SEGMENTS;
  my $max_segment = $self->config('max_segment') || MAX_SEGMENT;

  my (@segments,$class,$start,$stop);
  if ($name =~ /([\w._-]+):(-?\d+),(-?\d+)$/ or
      $name =~ /([\w._-]+):(-?[\d,]+)(?:-|\.\.)?(-?[\d,]+)$/) {
    $name = $1;
    $start = $2;
    $stop = $3;
    $start =~ s/,//g; # get rid of commas
    $stop  =~ s/,//g;
  }

  elsif ($name =~ /^(\w+):(.+)$/) {
    $class = $1;
    $name  = $2;
  }

  my @argv = (-name  => $name);
  push @argv,(-class => $class) if defined $class;
  push @argv,(-start => $start) if defined $start;
  push @argv,(-stop  => $stop)  if defined $stop;
  @segments = $name =~ /\*/ ? $db->get_feature_by_name(@argv) 
                            : $db->segment(@argv);

  # Here starts the heuristic part.  Try various abbreviations that
  # people tend to use for chromosomal addressing.
  if (!@segments && $name =~ /^([\dIVXA-F]+)$/) {
    my $id = $1;
    foreach (qw(CHROMOSOME_ Chr chr)) {
      my $n = "${_}${id}";
      my @argv = (-name  => $n);
      push @argv,(-class => $class) if defined $class;
      push @argv,(-start => $start) if defined $start;
      push @argv,(-stop  => $stop)  if defined $stop;
      @segments = $name =~ /\*/ ? $db->get_feature_by_name(@argv) 
                                : $db->segment(@argv);
      last if @segments;
    }
  }

  # try to remove the chr CHROMOSOME_I
  if (!@segments && $name =~ /^(chromosome_?|chr)/i) {
    (my $chr = $name) =~ s/^(chromosome_?|chr)//i;
    @segments = $db->segment($chr);
  }

  # try the wildcard  version, but only if the name is of significant length
  if (!@segments && length $name > 3) {
    @argv = (-name => "$name*");
    push @argv,(-start => $start) if defined $start;
    push @argv,(-stop  => $stop)  if defined $stop;
    @segments = $name =~ /\*/ ? $db->get_feature_by_name(@argv) 
                              : $db->segment(@argv);
  }

  # try any "automatic" classes that have been defined in the config file
  if (!@segments && !$class &&
      (my @automatic = split /\s+/,$self->setting('automatic classes') || '')) {
    my @names = length($name) > 3 && 
      $name !~ /\*/ ? ($name,"$name*") : $name;  # possibly add a wildcard
  NAME:
      foreach $class (@automatic) {
	for my $n (@names) {
	  @argv = (-name=>$n);
	  push @argv,(-start => $start) if defined $start;
	  push @argv,(-stop  => $stop)  if defined $stop;
	  # we are deliberately doing something different in the case that the user
	  # typed in a wildcard vs an automatic wildcard being added
	  @segments = $name =~ /\*/ ? $db->get_feature_by_name(-class=>$class,@argv)
	                            : $db->segment(-class=>$class,@argv);
	  last NAME if @segments;
	}
      }
  }

  # user wanted multiple locations, so user gets them
  return @segments if $name =~ /\*/;

  # Otherwise we try to merge segments that are adjacent if we can!

  # This tricky bit is called when we retrieve multiple segments or when
  # there is an unusually large feature to display.  In this case, we attempt
  # to split the feature into its components and offer the user different
  # portions to look at, invoking merge() to select the regions.
  my $max_length = 0;
  foreach (@segments) {
    $max_length = $_->length if $_->length > $max_length;
  }
  if (@segments > 1 || $max_length > $max_segment) {
    my @s     = $db->fetch_feature_by_name(-class => $segments[0]->class,
					   -name  => $segments[0]->seq_id,
					   -automerge=>0);
    @segments     = $self->merge($db,\@s,($self->get_ranges())[-1])
      if @s > 1 && @s < TOO_MANY_SEGMENTS;
  }
  @segments;
}

sub get_ranges {
  my $self      = shift;
  my @ranges	= split /\s+/,$self->setting('zoom levels') || DEFAULT_RANGES;
  @ranges;
}


# utility called by hits_on_overview
sub _hits_to_html {
  my $self = shift;
  my ($ref,$gd,$boxes) = @_;
  my $source   = $self->source;
  my $self_url = url(-relative=>1);
  $self_url   .= "?source=$source";

  my $signature = md5_hex(rand().rand()); # just a big random number
  my ($width,$height) = $gd->getBounds;
  my $url       = $self->generate_image($gd,$signature);
  my $img       = img({-src=>$url,-align=>'CENTER',
		       -usemap=>"#$ref",
		       -width => $width,
		       -height => $height,
		       -border=>0});
  my $html = "\n";
  $html   .= $img;
  $html   .= qq(<br><map name="$ref">\n);

  # use the scale as a centering mechanism
  my $ruler   = shift @$boxes;
  my $length  = $ruler->[0]->length/RULER_INTERVALS;
  $width   = ($ruler->[3]-$ruler->[1])/RULER_INTERVALS;
  for my $i (0..RULER_INTERVALS-1) {
    my $x = $ruler->[1] + $i * $width;
    my $y = $x + $width;
    my $start = int($length * $i);
    my $stop  = int($start + $length);
    my $href      = $self_url . ";ref=$ref;start=$start;stop=$stop";
    $html .= qq(<AREA SHAPE="RECT" COORDS="$x,$ruler->[2],$y,$ruler->[4]" HREF="$href">\n);
  }

  foreach (@$boxes){
    my ($start,$stop) = ($_->[0]->start,$_->[0]->end);
    my $href      = $self_url . ";ref=$ref;start=$start;stop=$stop";
    $html .= qq(<AREA SHAPE="RECT" COORDS="$_->[1],$_->[2],$_->[3],$_->[4]" HREF="$href">\n);
  }
  $html .= "</map>\n";
  $html;
}

# I know there must be a more elegant way to insert commas into a long number...
sub commas {
  my $i = shift;
  $i = reverse $i;
  $i =~ s/(\d{3})/$1,/g;
  chop $i if $i=~/,$/;
  $i = reverse $i;
  $i;
}

sub merge {
  my $self = shift;
  my ($db,$features,$max_range) = @_;
  $max_range ||= 100_000;

  my (%segs,@merged_segs);
  push @{$segs{$_->ref}},$_ foreach @$features;
  foreach (keys %segs) {
    push @merged_segs,_low_merge($db,$segs{$_},$max_range);
  }
  return @merged_segs;
}

sub _low_merge {
  my ($db,$features,$max_range) = @_;

  my ($previous_start,$previous_stop,$statistical_cutoff,@spans);
  patch_biographics() unless $features->[0]->can('low');

  my @features = sort {$a->low<=>$b->low} @$features;

  # run through the segments, and find the mean and stdev gap length
  # need at least 10 features before this becomes reliable
  if (@features >= 10) {
    my ($total,$gap_length,@gaps);
    for (my $i=0; $i<@$features-1; $i++) {
      my $gap = $features[$i+1]->low - $features[$i]->high;
      $total++;
      $gap_length += $gap;
      push @gaps,$gap;
    }
    my $mean = $gap_length/$total;
    my $variance;
    $variance += ($_-$mean)**2 foreach @gaps;
    my $stdev = sqrt($variance/$total);
    $statistical_cutoff = $stdev * 2;
  } else {
    $statistical_cutoff = $max_range;
  }

  my $ref = $features[0]->ref;

  for my $f (@features) {
    my $start = $f->low;
    my $stop  = $f->high;

    if (defined($previous_stop) &&
	( $start-$previous_stop >= $max_range ||
	  $previous_stop-$previous_start >= $max_range ||
	  $start-$previous_stop >= $statistical_cutoff)) {
      push @spans,$db->segment($ref,$previous_start,$previous_stop);
      $previous_start = $start;
      $previous_stop  = $stop;
    }

    else {
      $previous_start = $start unless defined $previous_start;
      $previous_stop  = $stop;
    }

  }
  my $class = $features[0]->factory->refclass;
  push @spans,$db ? $db->segment(-name=>$ref,-class=>$class,-start=>$previous_start,-end=>$previous_stop)
                  : Bio::Graphics::Feature->new(-start=>$previous_start,-stop=>$previous_stop,-ref=>$ref);
  return @spans;
}

# THESE SHOULD BE MIGRATED INTO BIO::GRAPHICS::FEATURE
# These fix inheritance problems in Bio::Graphics::Feature
sub patch_biographics {
  eval << 'END';
sub Bio::Graphics::Feature::low {
  my $self = shift;
  return $self->start < $self->end ? $self->start : $self->end;
}

sub Bio::Graphics::Feature::high {
  my $self = shift;
  return $self->start > $self->end ? $self->start : $self->end;
}
END
}

=head2 make_aggregators()

  @agg = $browser->make_aggregators(@string);

This interprets the aggregators option, returning a list of strings or
Aggregator objects.  Items with simple names like "alignment" are
passed as-is to DBGFF.  Items using the syntax:

   aggregate_name{subpart1,subpart2,subpart3/mainpart}

are turned into a Bio::DB::GFF::Aggregator object.

=cut

sub make_aggregators {
  my $self = shift;
  my @agg  = @_;
  require Bio::DB::GFF::Aggregator;

  my @result;
  foreach (@agg) {
    my($agg_name,$subparts,$mainpart) = /^(\w+)\{([^\/\}]+)\/?(.*)\}$/;
    unless ($agg_name) {
      push @result,$_;
      next;
    }
    my @subparts = split /,\s*/,$subparts;
    my @args = (-method    => $agg_name,
		-sub_parts => \@subparts);
    push @args,(-main_method => $mainpart) if $mainpart;
    warn "making an aggregator with (@args), subparts = @subparts" if DEBUG;
    push @result,Bio::DB::GFF::Aggregator->new(@args);
  }
  \@result;
}

sub overview_pad {
  my $self   = shift;
  my $tracks = shift;
  $tracks ||= [$self->config->overview_tracks];
  my $max = 0;
  foreach (@$tracks) {
    my $key = $self->setting($_=>'key');
    next unless defined $key;
    $max = length $key if length $key > $max;
  }
  foreach (@_) {  #extra
    $max = length if length > $max;
  }
  return MIN_OVERVIEW_PAD unless $max;
  $max * gdMediumBoldFont->width + 3;
}


package Bio::Graphics::BrowserConfig;
use strict;
use Bio::Graphics::FeatureFile;
use Text::Shellwords;
use Carp 'croak';

use vars '@ISA';
@ISA = 'Bio::Graphics::FeatureFile';

sub labels {
  grep { !($_ eq 'overview' || /:(\d+|overview)$/) } shift->configured_types;
}

sub overview_tracks {
  grep { $_ eq 'overview' || /:overview$/ } shift->configured_types;
}

sub label2type {
  my ($self,$label,$length) = @_;
  my $l = $self->semantic_label($label,$length);
  return shellwords($self->setting($l,'feature')||'');
}

sub style {
  my ($self,$label,$length) = @_;
  my $l = $self->semantic_label($label,$length);
  return $l eq $label ? $self->SUPER::style($l) : ($self->SUPER::style($label),$self->SUPER::style($l));
}

sub semantic_label {
  my ($self,$label,$length) = @_;
  return $label unless defined $length && $length > 0;
  # look for:
  # 1. a section like "Gene:100000" where the cutoff is less than the length of the segment
  #    under display.
  # 2. a section like "Gene" which has no cutoff to use.
  if (my @lowres = map { [split ':'] }
      grep {/$label:(\d+)/ && $1 <= $length}
      $self->configured_types) {
    ($label) = map {join ':',@$_} sort {$b->[1] <=> $a->[1]} @lowres;
  }
  $label
}

# override inherited in order to be case insensitive
# and to account for semantic zooming
sub type2label {
  my $self = shift;
  my ($type,$length) = @_;
  $length ||= 0;
  my $array  = $self->SUPER::type2label(lc $type) or return;
  my @normal = grep {!/:\d+$/} @$array;
  my @lowres = map {$_->[0]} sort {$b->[1] <=> $a->[1]} map { [split ':'] }
    grep {/:(\d+)$/ && $1 <= $length} @$array;
  $lowres[0] || $normal[0];
}

# override inherited in order to allow for semantic zooming
sub feature2label {
  my $self = shift;
  my ($feature,$length) = @_;
  my $type  = eval {$feature->type} || $feature->primary_tag or return;
  (my $basetype = $type) =~ s/:.+$//;
  my $label = $self->type2label($type,$length)
    || $self->type2label($basetype,$length) 
      || $type;
  $label;
}

sub invert_types {
  my $self = shift;
  my $config  = $self->{config} or return;
  my %inverted;
  for my $label (keys %{$config}) {
    next if $label=~/:?overview$/;   # special case
    my $feature = $config->{$label}{'feature'} or next;
    foreach (shellwords($feature||'')) {
      push @{$inverted{lc $_}},$label;
    }
  }
  \%inverted;
}

sub default_labels {
  my $self = shift;
  my $defaults = $self->setting('general'=>'default features');
  return shellwords($defaults||'');
}

# return a hashref in which keys are the thresholds, and values are the list of
# labels that should be displayed
sub summary_mode {
  my $self = shift;
  my $summary = $self->settings(general=>'summary mode') or return {};
  my %pairs = $summary =~ /(\d+)\s+{([^\}]+?)}/g;
  foreach (keys %pairs) {
    my @l = shellwords($pairs{$_}||'');
    $pairs{$_} = \@l
  }
  \%pairs;
}

# override make_link to allow for code references
sub make_link {
  my $self     = shift;
  my $feature  = shift;
  my $label    = $self->feature2label($feature) or return;
  my $link     = $self->code_setting($label,'link');
  $link        = $self->code_setting(general=>'link') unless defined $link;
  return unless $link;
  return $link->($feature) if ref($link) eq 'CODE';
  return $self->link_pattern($link,$feature);
}

# make the title of an image area
sub make_title {
  my $self = shift;
  my $feature = shift;
  my $title;
 TRY: {
    my $label    = $self->feature2label($feature) or last TRY;
    my $link     = $self->code_setting($label,'title');
    $link      ||= $self->code_setting(general=>'title');
    $link or last TRY;
    $title       = $link->($feature) if ref($link) eq 'CODE';
    $title     ||= $self->link_pattern($link,$feature);
  }

  $title ||= eval {
    if ($feature->method =~ /^(similarity|alignment)$/i) {
      $feature->seq_id||''.":".
	$feature->start."..".
	  $feature->end.' '.
	    $feature->info||''.":".
	      $feature->target->start."..".$feature->target->end;
    } else {
      $feature->class||'' .":".
	$feature->info||'' . " ".
	  $feature->seq_id||''.':'.
	    $feature->start."..".
	      $feature->end;
    }
  };

  return $title;
}


=head1 SEE ALSO

L<Bio::Graphics::Panel>,
L<Bio::Graphics::Glyph>,
L<Bio::Graphics::Feature>,
L<Bio::Graphics::FeatureFile>

=head1 AUTHOR

Lincoln Stein E<lt>lstein@cshl.orgE<gt>.

Copyright (c) 2001 Cold Spring Harbor Laboratory

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  See DISCLAIMER.txt for
disclaimers of warranty.

=cut




1;

__END__
