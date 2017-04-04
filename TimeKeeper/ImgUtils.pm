package TimeKeeper::ImgUtils;

# This module contains some Image processing functions that are used in the GUI.

use strict;


BEGIN
{
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

	# set the version for version checking
	$VERSION     = 1.00;

	@ISA         = qw(Exporter);
	@EXPORT      = qw(
		create_mask_from_xpm
		replace_color_xpm
		downsample_xpm upsample_xpm blur_xpm
		visit_pixels_xpm
	);
	@EXPORT_OK   = qw(
		set_rgb_function
	);
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


# This function initializes functions that are used to retrieve rgb colors.
# These functions can be GUI dependent (like color depth) and to make this
# module independent of a specific GUI implementation, it is factored out.
my $fn_get_rgb;
sub set_rgb_function
{
	my ($get_rgb) = @_;

	$fn_get_rgb = $get_rgb;
}

# This function uses $fn_get_rgb (set by set_rgb_function) to retrieve the
# rgb values for the specified color.
# Returns array (r, g, b) with color components.
sub fn_get_rgb
{
	my ($color) = @_;

	die "\$fn_get_rgb not set, use set_rgb_function()" unless $fn_get_rgb;

	my @rgb;
	if (lc($color) eq "none")
	{
		# Transparent color should not contribute
		@rgb = ( 0, 0, 0 );
	}
	else
	{
		@rgb = &$fn_get_rgb($color);
		if (@rgb > 1)
		{
			# This is the array
		}
		else
		{
			my $rgb = shift;
			if (ref $rgb)
			{
				# It is a reference to an array
				@rgb = @$rgb;
			}
			elsif ($rgb =~ /^\s*#?([\da-f]{3}+)\s*$/i)
			{
				# There is a multiple of 3 digits in the form #xxx
				my $n = length($rgb) / 3;
				@rgb = (
					hex(substr($rgb, 0*$n, $n)),
					hex(substr($rgb, 1*$n, $n)),
					hex(substr($rgb, 2*$n, $n)),
				);
			}
			elsif ($rgb =~ /^\s*(\d+)\s+(\d+)\s+(\d+)\s*$/)
			{
				@rgb = ( $1, $2, $3 );
			}
			else
			{
				die "Returned color is of unknown format: '$rgb'";
			}
		}
	}
	#print "RGB value of '$color' is: (@rgb)\n";
	return @rgb;
}

# Retrieve the strings of the xpm.
# Arguments:
# - $xpm: Either the Pixmap data or a Pixmap object.
# Returns array with lines.
sub get_strings_xpm
{
	my ($xpm) = @_;

	my $data = (ref $xpm) ? $xpm->cget("-data") : $xpm;
	# Read all the C-strings defined in the XPM
	my @strings;
	$data =~ /=\s*{/gc;  # find opening brace and remember position
	while (1)
	{
		$data =~ /"(.*?)"\s*([,}])/gc;
		push @strings, $1;
		last if $2 eq "}";  # closing brace
	}

	return @strings;
}

# Retrieve the parts of the xpm.
# Arguments:
# - $xpm_strings: Either the Pixmap data or a Pixmap object.
# Returns array with the folowing elements:
#   0: Dimensions: Array with the following elements: width, height, number of
#      colors and characters per pixel.
#   1: Pixel to Color: Hash with pixel character(s) to color. (colors are in
#      upper case)
#   2: Color to Pixel: Hash with color to pixel character(s). (colors are in
#      upper case)
#   3: Pixels: Array of Rows of pixels;
sub get_sections_xpm
{
	my ($xpm_strings) = @_;

	# Get the dimensions (line 0)
	my ($width, $height, $numcolors, $chars_per_pixel) =
		split /\D+/, $$xpm_strings[0];
	#print "DIMENSIONS: ${width}x$height; $numcolors colors; $chars_per_pixel chars per pixel\n";

	# Retrieve the colors (lines 1 .. numcolors)
	my (%pix2col, %col2pix);
	foreach (@$xpm_strings[1..$numcolors])
	{
		if (/^(.{$chars_per_pixel})\s*c\s*(\S+)/i)
		{
			my $pix = $1;
			my $col = lc $2;
			#print "COLOR: '$pix' = '$col'\n";
			$pix2col{$pix} = $col;
			$col2pix{$col} = $pix;
		}
	}

	# Retrieve the pixel data (lines $numcolors+1..$numcolors+1+height-1)
	my @pixels;
	foreach (@$xpm_strings[$numcolors+1 .. $numcolors+1+$height-1])
	{
		#print "DATA '$_'\n";
		my @pix_row;
		for (my $c = 0; $c < $width; ++$c)
		{
			my $pix = substr($_, $c*$chars_per_pixel, $chars_per_pixel);
			push @pix_row, $pix;
		}
		push @pixels, \@pix_row;
	}

	# Return the sections
	return (
		[ $width, $height, $numcolors, $chars_per_pixel ],
		\%pix2col, \%col2pix,
		\@pixels
	);
}

# Construct xpm data from the sections.
# Returns xpm data.
# Create a Pixmap from this by:
#   $mw->Pixmap(-data => construct_xpm(...));
sub construct_xpm
{
	my ($pix2col, $pixels) = @_;

	my ($width, $height) = get_size_image($pixels);
	my $chars_per_pixel = length $$pixels[0][0];  # length of first pixel
	my $numcolors = keys %$pix2col;  # number of colors

	# XPM header
	my $xpm_data = <<"DATA";
/* XPM */
static char * xpm[] = {
DATA
	# Dimensions
	$xpm_data .= qq("$width $height $numcolors $chars_per_pixel",\n);
	# Colors
	foreach my $pix (sort keys %$pix2col)
	{
		my $col = $$pix2col{$pix};
		$xpm_data .= qq("$pix c $col",\n);
	}
	# Pixels
	foreach my $row (@$pixels)
	{
		$xpm_data .= qq(");
		$xpm_data .= $_ foreach @$row;
		$xpm_data .= qq(",\n);
	}
	# End the structure
	$xpm_data =~ s/,\s*$/};\n/;

	#print "CONSTRUCTED:\n$xpm_data\n";
	return $xpm_data;
}

# Converts xpm pixels and palette (pix2col) into a truecolor image.
# Returns a reference to an array of rows of colors.
sub get_truecolor_xpm
{
	my ($pix2col, $pixels) = @_;

	my ($width, $height) = get_size_image($pixels);

	# Fill in the colors for the pixels
	my $image = [];
	foreach my $row (@$pixels)
	{
		push @$image, [ map $$pix2col{$_}, @$row ];
	}

	return $image;
}

# Converts a truecolor image into an xpm pixels and palette.
# Returns sections like get_sections_xpm() with pixels and palette.
sub get_palette_xpm
{
	my ($image) = @_;

	my ($width, $height) = get_size_image($image);

	# Create a histogram of colors
	my %histo;
	foreach my $row (@$image)
	{
		foreach my $color (@$row)
		{
			++$histo{$color}
		}
	}

	# Only use characters 0x20..0x7F (96 characters).
	# Calculate the number of characters needed.
	my $numcolors = keys %histo;
	my $c = $numcolors;
	my $chars_per_pixel = 1;
	while ($c > 96)
	{
		$c /= 96;  # get factor of 96 out
		++$chars_per_pixel;  # add a character
	}
	# $n is the number of characters per pixel

	# Assign pixel characters
	my @alphabet =
		grep !/"/,  # forbidden characters
		map chr $_,  # as characters
		( 0x20..0x7F );  # the set
	#print "ALPHABET='@alphabet'\n";
	my %pix2col;
	my %col2pix;
	my @pix = ( 0 ) x $chars_per_pixel;
	foreach my $color (sort keys %histo)
	{
		# Put pixel in palette
		my $pix = join "", map $alphabet[$_], @pix;
		#print "PIX='$pix'\n";
		$pix2col{$pix} = $color;
		$col2pix{$color} = $pix;
		# Determine next pixel characters
		foreach (@pix)
		{
			if ($_ < @alphabet-1)
			{
				# There is space to increase
				++$_;  # increase value
				last;
			}
			else
			{
				# There is no space, reset and loop to
				# increase next
				$_ = 0;
			}
		}
	}

	# Replace colors by pixels
	my @pixels;
	foreach my $row (@$image)
	{
		push @pixels, [ map $col2pix{$_}, @$row ];
	}

	# Return the sections
	return (
		[ $width, $height, $numcolors, $chars_per_pixel ],
		\%pix2col, \%col2pix,
		\@pixels
	);
}

# Convert xpm to truecolor image.
# Returns 2D array with pixels with truecolor value. In list context, an array
# with pixels, width, height is returned.
sub get_truecolor_from_xpm
{
	my ($xpm) = @_;

	# Get truecolor image from xpm
	my @strings = get_strings_xpm $xpm;
	my ($dimensions, $pix2col, $col2pix, $pixels) = get_sections_xpm \@strings;
	my ($width, $height, $numcolors, $chars_per_pixel) = @$dimensions;
	my $image = get_truecolor_xpm $pix2col, $pixels;

	if (wantarray)
	{
		return ($image, $width, $height);
	}
	else
	{
		return $image;
	}
}

# Convert truecolor image to xpm image.
# Returns xpm image data.
sub get_xpm_from_truecolor
{
	my ($image) = @_;

	# Construct xpm from image
	my ($dimensions, $pix2col, $col2pix, $pixels) = get_palette_xpm $image;
	my $xpm = construct_xpm $pix2col, $pixels;

	return $xpm;
}

# Gets width and height for image.
# Returns array (width, height).
sub get_size_image
{
	my ($image) = @_;

	my $height = @$image;  # number of rows
	my $width = @$image ? @{$$image[0]} : 0;  # number of pixels in 1st row

	return ($width, $height);
}

# Construct xbm data from the sections.
# Returns xbm data.
# Create a Bitmap from this by:
#   $mw->Bitmap("name", -data => construct_xbm(...));
sub construct_xbm
{
	my ($pixels) = @_;

	my ($width, $height) = get_size_image($pixels);
	my $hot_x = int $width / 2;  # in the middle
	my $hot_y = int $height / 2;  # in the middle

	# Dimensions and header
	my $xbm_data = <<"DATA";
#define xbm_width $width
#define xbm_height $height
#define xbm_x_hot $hot_x
#define xbm_y_hot $hot_y
static unsigned char xbm_bits[] = {
DATA
	# Pixels
	$xbm_data .= <<"DATA";
   0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00,
   0x00, 0xfe, 0x07, 0x00, 0x00, 0xff, 0x3f, 0x00, 0x80, 0xff, 0x7f, 0x00,
   0xc0, 0xff, 0xff, 0x01, 0xe0, 0xff, 0xff, 0x03, 0xe0, 0xff, 0xff, 0x03,
   0xf0, 0xff, 0xff, 0x07, 0xf0, 0xff, 0xff, 0x0f, 0xf0, 0xff, 0xff, 0x1f,
   0xf8, 0xff, 0xff, 0x1f, 0xf8, 0xff, 0xff, 0x3f, 0xf8, 0xff, 0xff, 0x3f,
   0xf8, 0xff, 0xff, 0x3f, 0xf8, 0xff, 0xff, 0x1f, 0xf8, 0xff, 0xff, 0x1f,
   0xf0, 0xff, 0xff, 0x1f, 0xf0, 0xff, 0xff, 0x1f, 0xf0, 0xff, 0xff, 0x0f,
   0xe0, 0xff, 0xff, 0x0f, 0xe0, 0xff, 0xff, 0x07, 0xe0, 0xff, 0xff, 0x07,
   0xe0, 0xff, 0xff, 0x07, 0xe0, 0xff, 0xff, 0x07, 0xc0, 0xff, 0xff, 0x03,
   0x80, 0xff, 0xff, 0x03, 0x00, 0xfe, 0xff, 0x00, 0x00, 0xe0, 0x0f, 0x00,
   0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
DATA
	# End the structure
	$xbm_data =~ s/,\s*$/};\n/;

	#print "CONSTRUCTED:\n$xbm_data\n";
	return $xbm_data;
}

# This function creates a Bitmap mask from a Pixmap object or data by masking
# every pixel that is transparent.
# Arguments:
# - $xpm: Either the Pixmap data or a Pixmap object.
# - @$trans_colors: Array of colors that should be masked (ie 0 in mask).
#   Defaults to [ "none" ].
# Returns the data for a Bitmap.
# Example:
#   my $icon_image = $mw->Pixmap(...);
#   my $icon_mask_data = create_mask_from_xpm($icon_image);
#   $mw->DefineBitmap("iconmask", 32, 32, $icon_mask_data);
#   $mw->iconimage($icon_image);
#   $mw->iconmask("iconmask");
sub create_mask_from_xpm
{
	my ($xpm, $trans_colors) = @_;
	$trans_colors = [ "none" ] unless defined $trans_colors;

	my @strings = get_strings_xpm $xpm;
	my ($dimensions, $pix2col, $col2pix, $pixels) =
		get_sections_xpm \@strings;
	# Get the dimensions
	my ($width, $height, $numcolors, $chars_per_pixel) = @$dimensions;
	# Retrieve the transparent colors
	my $reTransColor = join "|", map qr/\Q$_\E/i, @$trans_colors;
	$reTransColor = qr/^(?:$reTransColor)$/;
	my @transparent;
	while (my ($pix, $col) = each %$pix2col)
	{
		push @transparent, $pix if $col =~ $reTransColor;
	}
	my $reTransPixel = join "|", map qr/\Q$_\E/, @transparent;
	$reTransPixel = qr/$reTransPixel/;

	# Process data rows and construct mask_data
	my @mask_data;
	foreach my $row (@$pixels)
	{
		#print "DATA '", join("", @$row), "'\n";
		my $mask_row = "";
		foreach my $pix (@$row)
		{
			$mask_row .= ($pix =~ $reTransPixel) ? "." : "1";
		}
		push @mask_data, $mask_row;
		#print "MASK '$mask_row'\n";
	}
	# Convert into bit-string in 'standard' Bitmap way
	my $mask_data = pack "b$width" x $height, @mask_data;
	return $mask_data;
}

# Replace colors in the $xpm.
# Arguments:
# - %$replacements: Hash with from-color and to-color.
# - $xpm: Either the Pixmap data or a Pixmap object.
# Returns Pixmap data for a new Pixmap.
sub replace_color_xpm
{
	my ($replacements, $xpm) = @_;

	my @strings = get_strings_xpm $xpm;
	my ($dimensions, $pix2col, $col2pix, $pixels) =
		get_sections_xpm \@strings;

	# Find the colors and replace them
	while (my ($col1, $col2) = each %$replacements)
	{
		my $pix = $$col2pix{lc $col1};
		$$pix2col{$pix} = lc $col2 if defined $pix;
	}

	return construct_xpm $pix2col, $pixels;
}

# Translates a color (or colorname) into an (r,g,b) triplet.
# Use $bits number of bits per color. Defaults to 8.
my $ScreenBitPlanes = -1;
sub get_rgb
{
	my ($color, $bits) = @_;
	$bits = 8 unless defined $bits;

	# Determine the number of bitplanes
	if ($ScreenBitPlanes < 0)
	{
		my ($r, $g, $b) = fn_get_rgb "white";  # 'full-scale'
		$ScreenBitPlanes = 1;
		while ($r > 1)
		{
			$r >>= 1;  # shift out bit
			++$ScreenBitPlanes;  # add number of bits
		}
		#print "NUMBER OF BITPLANES: $ScreenBitPlanes\n";
	}

	# Determine the color
	my ($r, $g, $b) = fn_get_rgb $color;

	if ($ScreenBitPlanes < 8)
	{
		my $lshift = $ScreenBitPlanes - 8;  # amount to shift left
		$r <<= $lshift;
		$g <<= $lshift;
		$b <<= $lshift;
	}
	elsif ($ScreenBitPlanes > 8)
	{
		my $rshift = $ScreenBitPlanes - 8;  # amount to shift right
		$r >>= $rshift;
		$g >>= $rshift;
		$b >>= $rshift;
	}

	# Return the properly scaled color
	return ($r, $g, $b);
}

# Translate rgb triplet into #RRGGBB color.
# Use $bits number of bits per color, should be multiple of 4. Defaults to 8.
sub get_rgbcolor
{
	my ($r, $g, $b, $bits) = @_;
	$bits = 8 unless defined $bits;

	die "Bitplanes not a multiple of 4." if ($bits % 4) != 0;
	my $nybbles = $bits / 4;
	my $colformat = "#%0${nybbles}X%0${nybbles}X%0${nybbles}X";
	return sprintf $colformat, $r, $g, $b;
}

# Add $other_color to @$this_color.
# $other_color can be either a scalar or a reference to an [r,g,b] array.
# $this_color should be a reference to an [r,g,b] array
sub add_color
{
	my ($this_color, $other_color) = @_;

	if (lc($other_color) eq "none")
	{
		# Transparent color does not contribute
	}
	else
	{
		# Get rgb colors
		my ($r2, $g2, $b2) = ref($other_color) ? @$other_color : get_rgb $other_color;
		# Add the colors
		$$this_color[0] += $r2;
		$$this_color[1] += $g2;
		$$this_color[2] += $b2;
	}
}

# Divide @$this_color by constant.
sub div_color
{
	my ($this_color, $constant) = @_;

	$_ /= $constant foreach @$this_color;
}

# Multiply @$this_color by constant.
sub mul_color
{
	my ($this_color, $constant) = @_;

	$_ *= $constant foreach @$this_color;
}

# Clip @$this_color between min and max.
sub clip_color
{
	my ($this_color, $min, $max) = @_;

	foreach (@$this_color)
	{
		$_ = $min if $_ < $min;
		$_ = $max if $_ > $max;
	}
}

# This function down-samples a true-color pixel image. This decreases the size
# of the image.
# Arguments:
# - $factor: Number of input pixels per output pixel. This can be an array to
#     define a separate x and y factor.
# - $undim: Averaging pixels removes the extremes too. This causes the image
#     to look dim. If this option is set, the contrast is increased.
# - $image: 2D array with pixels
# Returns true-color pixel image.
sub downsample_pixels
{
	my ($factor, $undim, $image) = @_;

	# Determine factor for x and y dimensions.
	my ($factorx, $factory);
	if (ref $factor)
	{
		($factorx, $factory) = @$factor;
	}
	else
	{
		$factorx = $factory = $factor;
	}
	my ($width, $height) = get_size_image $image;

	# Resample the image, averaging all pixels per block
	my $image2 = [];
	for (my $y = 0; $y < $height; $y += $factory)
	{
		for (my $x = 0; $x < $width; $x += $factorx)
		{
			my $newcol;
			# Average over factorx x factory block
			my @rgb;  # average color
			my $area;  # area of non-transparent pixels
			my $transparent_area;  # area of transparent pixels
			for (my $dy = 0; $dy < $factory; ++$dy)
			{
				next unless exists $$image[$y+$dy];
				for (my $dx = 0; $dx < $factorx; ++$dx)
				{
					next unless exists $$image[$y+$dy][$x+$dx];
					my $color = $$image[$y+$dy][$x+$dx];
					if ($color ne 'none')
					{
						add_color \@rgb, $color;
						++$area;  # one additional pixel
					}
					else
					{
						++$transparent_area;
					}
				}
			}
			my $alpha = $area / ($transparent_area + $area);
			if ($alpha > 0.3)
			{
				# Make a colored pixel
				div_color \@rgb, $area;
				if ($undim)
				{
					# Increase constrast a bit
					# Averaging causes the uniformly
					# distributed colors to become more
					# centered. To counter this, increase
					# the contrast, depending on the area.
					# To go from [d,1-d] to [0,1], subtract
					# d, then multiply by 1/(1-2d)
					my $d = $area/70;  # area = 4..9
					add_color \@rgb, [ -255*$d, -255*$d, -255*$d ];
					mul_color \@rgb, 1/(1-2*$d);
					clip_color \@rgb, 0, 255;
				}
				$newcol = get_rgbcolor @rgb;
			}
			else
			{
				# Make a transparent pixel
				$newcol = "none";
			}
			$$image2[$y / $factory][$x / $factorx] = $newcol;
		}
	}

	return $image2;
}

# This function up-samples a true-color pixel image. This increases the size
# of the image.
# - $factor: Number of output pixels per input pixel. This can be an array to
#     define a separate x and y factor.
# - $image: 2D array with pixels
# Returns true-color pixel image.
sub upsample_pixels
{
	my ($factor, $image) = @_;

	# Determine factor for x and y dimensions.
	my ($factorx, $factory);
	if (ref $factor)
	{
		($factorx, $factory) = @$factor;
	}
	else
	{
		$factorx = $factory = $factor;
	}
	my ($width, $height) = get_size_image $image;

	# Resample and assign each pixel to a block of pixels
	my $image2 = [];
	for (my $y = 0; $y < $height; ++$y)
	{
		for (my $x = 0; $x < $width; ++$x)
		{
			my $col = $$image[$y][$x];
			for (my $dy = 0; $dy < $factory; ++$dy)
			{
				for (my $dx = 0; $dx < $factorx; ++$dx)
				{
					$$image2[$factory*$y+$dy][$factorx*$x+$dx] = $col;
				}
			}
		}
	}

	return $image2;
}

# This function down-samples an xpm image. This decreases the size of the image.
# Arguments:
# - $factor: Number of input pixels per output pixel. This can be an array to
#     define a separate x and y factor.
# - $undim: Averaging pixels removes the extremes too. This causes the image
#     to look dim. If this option is set, the contrast is increased.
# - $xpm: Either the Pixmap data or a Pixmap object.
# Returns Pixmap data for a new Pixmap.
sub downsample_xpm
{
	my ($factor, $undim, $xpm) = @_;

	my $image = get_truecolor_from_xpm $xpm;

	# Resample the image
	my $image = downsample_pixels $factor, $undim, $image;

	return get_xpm_from_truecolor $image;
}

# This function up-samples an xpm image. This increases the size of the image.
# Arguments:
# - $factor: Number of output pixels per input pixel. This can be an array to
#     define a separate x and y factor.
# - $xpm: Either the Pixmap data or a Pixmap object.
# Returns Pixmap data for a new Pixmap.
sub upsample_xpm
{
	my ($factor, $xpm) = @_;

	my $image = get_truecolor_from_xpm $xpm;

	# Resample the image
	my $image = upsample_pixels $factor, $image;

	return get_xpm_from_truecolor $image;
}

# This function blurs a Pixmap image pixels.
# Arguments:
# - $method: Blurring method:
#   1: Just take average of (2*factor+1)^2 square of pixels
#   2: Scale down with factor, taking averages for each pixel. Then scale up
#      again with factor.
#   3: Like method 2, but increase contrast to counter the 'gray-ing' of the
#      averaging.
# - $factor: The number of neighboring pixels to consider.
# - $xpm: Either the Pixmap data or a Pixmap object.
# Returns Pixmap data for a new Pixmap.
sub blur_xpm
{
	my ($method, $factor, $xpm) = @_;

	my ($image, $width, $height) = get_truecolor_from_xpm $xpm;

	# Blur the image
	my $image2 = [];
	if ($method == 1)
	{
		# For every pixel, take the average of the area.
		for (my $y = 0; $y < $height; ++$y)
		{
			for (my $x = 0; $x < $width; ++$x)
			{
				my @rgb;
				my $area;
				foreach my $dy (-$factor..$factor)
				{
					next unless exists $$image[$y+$dy];
					foreach my $dx (-$factor..$factor)
					{
						next unless exists $$image[$y+$dy][$x+$dx];
						add_color \@rgb, $$image[$y+$dy][$x+$dx];
						++$area;  # one additional pixel
					}
				}
				div_color \@rgb, $area;
				my $newcol = get_rgbcolor @rgb;
				$$image2[$y][$x] = $newcol;
			}
		}
	}
	elsif ($method == 2)
	{
		$image2 = upsample_pixels $factor,
			downsample_pixels $factor, 0, $image;
	}
	elsif ($method == 3)
	{
		$image2 = upsample_pixels $factor,
			downsample_pixels $factor, 1, $image;
	}

	return get_xpm_from_truecolor $image2;
}

# Visit all the pixels in the XPM and call &$process_pixel() for each pixel.
# The arguments are: x, y, color. (color is a standard rgb color or 'none' for
# transparent pixels).
sub visit_pixels_xpm
{
	my ($xpm, $process_pixel) = @_;

	my ($image, $width, $height) = get_truecolor_from_xpm $xpm;

	# Visit the pixels and call the callback
	for (my $y = 0; $y < $height; ++$y)
	{
		for (my $x = 0; $x < $width; ++$x)
		{
			&$process_pixel($x, $y, $$image[$y][$x]);
		}
	}
}


1;


