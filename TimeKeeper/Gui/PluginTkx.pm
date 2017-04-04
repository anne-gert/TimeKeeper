package TimeKeeper::Gui::PluginTkx;

# This module implements a GUI-plugin, based on the Perl Tkx module for the
# TimeKeeper GUI.

use strict;
use base qw(TimeKeeper::Gui::PluginBase);

use Tkx;
#$Tkx::TRACE = 1;
Tkx::package_require('tooltip');
Tkx::tooltip__tooltip(delay => 750);
Tkx::package_require('BWidget');

use TimeKeeper::Gui qw/:plugin/;

use TimeKeeper::ImgUtils;


##############################################################################
### Constructors and factory methods

# Construct
sub new
{
	my $class = shift;

	my $self = $class->SUPER::new();
	# Set values
	$$self{AddCancelMenuItem} = 0;
	# Add my variables
	my %sub = (
		# references to widgets
		NormalIcons => undef,  # normal icons
		StoppedIcons => undef,  # icons when stopped

		# constants
	);
	@$self{keys %sub} = values %sub;

	return $self;
}


##############################################################################
### GUI draw and query functions

# Set this timer visually/behaviourally in edit-mode.
# If $preset is defined, display that value, otherwise keep the current value.
sub SetTimerEditMode
{
	my $self = shift;
	my ($timer, $preset) = @_;

	my $timerc = $self->{Timers}[$timer];
	my $ctrl_time = $timerc->{timectrl};
	my $timetext = $timerc->{timetext};
	# Go into edit-mode
	$ctrl_time->configure(-background => $self->{ColorEditable}, -insertontime => $self->{DefaultInsertOnTime});
	# Set edit-mode event-handlers
	$ctrl_time->g_bind("<Escape>", \&TimerEditCancel);
	$ctrl_time->g_bind("<Return>", \&TimerEditOk);
	$ctrl_time->g_bind("<Button-1>", undef);
	# Put right value in editbox
	$$timetext = $preset if defined $preset;
	$ctrl_time->selection_range(0, "end");
	$ctrl_time->g_focus;
}

# Set this timer visually/behaviourally in normal-mode.
sub SetTimerNormalMode
{
	my $self = shift;
	my ($timer, $is_active) = @_;

	my $timerc = $self->{Timers}[$timer];
	my $ctrl_time = $timerc->{timectrl};
	# Go out of edit-mode
	my $color = $self->{$is_active ? "ColorActive" : "ColorReadOnly"};
	$ctrl_time->configure(-background => $color, -insertontime => 0);
	# Set normal event-handlers
	$ctrl_time->g_bind("<Escape>", undef);
	$ctrl_time->g_bind("<Return>", undef);
	$ctrl_time->g_bind("<Button-1>", sub { EvtActivate $timer });
	# Put right value in editbox
	$ctrl_time->selection_clear;
}

# Draw specified timer in an active state.
sub DrawTimerActive
{
	my $self = shift;
	my ($timer, $is_edit) = @_;

	my $timerc = $self->{Timers}[$timer];
	$timerc->{descrctrl}->configure(-background => $self->{ColorActive});
	my $color = $self->{$is_edit ? "ColorEditable" : "ColorActive"};
	$timerc->{timectrl}->configure(-background => $color);
}

# Draw specified timer in an inactive state.
sub DrawTimerInactive
{
	my $self = shift;
	my ($timer, $is_edit) = @_;

	my $timerc = $self->{Timers}[$timer];
	$timerc->{descrctrl}->configure(-background => $self->{ColorEditable});
	my $color = $self->{$is_edit ? "ColorEditable" : "ColorReadOnly"};
	$timerc->{timectrl}->configure(-background => $color);
}

# Draw application in a running state.
sub DrawRunning
{
	my $self = shift;

	$self->GetMainWin->g_wm_iconphoto(@{$self->{NormalIcons}});
	$self->{CopyRightLabel}->configure(-foreground => "#EECC00");
}

# Draw application in a stopped state.
sub DrawStopped
{
	my $self = shift;

	$self->GetMainWin->g_wm_iconphoto(@{$self->{StoppedIcons}});
	$self->{CopyRightLabel}->configure(-foreground => "red");
}

# Set the title of the toplevel main window.
sub SetWindowTitle
{
	my $self = shift;
	my ($title) = @_;

	$self->GetMainWin->g_wm_title($title);
}

# Set the description of the specified timer.
sub SetTimerDescription
{
	my $self = shift;
	my ($timer, $description) = @_;

	${$self->{Timers}[$timer]{descrtext}} = $description;
}

# Set the group of the specified timer.
sub SetTimerGroup
{
	my $self = shift;
	my ($timer, $groupname, $groupcolor) = @_;

	$groupname = "" unless defined $groupname;
	$groupcolor = $self->{ColorWindowBackground} unless $groupcolor ne "";
	my $grouptextcolor = $self->GetTextColorForBackground($groupcolor);

	${$self->{Timers}[$timer]{groupname}} = $groupname;
	$self->{Timers}[$timer]{labelctrl}->configure(-background => $groupcolor, -foreground => $grouptextcolor);
}

# Set the time displayed in the specified timer.
sub SetTimerTime
{
	my $self = shift;
	my ($timer, $time) = @_;

	${$self->{Timers}[$timer]{timetext}} = $time;
}

# Get the time displayed in the specified timer.
sub GetTimerTime
{
	my $self = shift;
	my ($timer) = @_;

	return ${$self->{Timers}[$timer]{timetext}};
}

# Set the specified time (string) as wall-time on the clock.
sub SetWallTime
{
	my $self = shift;
	my ($time) = @_;

	$self->{LblClock}->configure(-text => $time);
}

# Popup the menu at position (x,y) on the widget.
sub ShowPopup
{
	my $self = shift;
	my ($menu, $widget, $x, $y) = @_;

	my $rootx = Tkx::winfo('rootx', $widget);
	my $rooty = Tkx::winfo('rooty', $widget);
	$menu->post($rootx + $x, $rooty + $y);
}


##############################################################################
### Miscellaneous GUI-stuff

# Run the GUI's main loop
sub Run
{
	my $self = shift;

	Tkx::MainLoop;
}

# Set a function to be repetitively (every $time milliseconds) called.
sub SetRepeatTimer
{
	my $self = shift;
	my ($time, $func) = @_;

	my $repeat; $repeat = sub {
		&$func();  # call the function
		Tkx::after($time, $repeat);  # re-schedule
	};
	Tkx::after($time, $repeat);
}

# Set data on the clipboard
sub SetClipboard
{
	my $self = shift;
	my ($data) = @_;

	my $mw = $self->GetMainWin;
	# For some reason, the (windows) clipboard likes to have unix
	# line-breaks.
	Tkx::clipboard_clear();
	# (Use "--" to mark end of clipboard_append() options.)
	Tkx::clipboard_append("--", dos2unix $data);
}

# Add the specified option with the specified value.
sub AddOption
{
	my $self = shift;
	my ($option, $value) = @_;

	Tkx::option_add($option, $value);
}

# Return the platform-specific RGB components of the specified color.
sub GetRgbRaw
{
	my $self = shift;
	my ($color) = @_;

	my @value = Tkx::SplitList(Tkx::winfo('rgb', $self->GetMainWin, $color));
	return @value;
}


##############################################################################
### Create window

# This function retrieves the widget's current font attributes in %$_ and calls
# &$change. It then configures the font again. This way, the default font can
# be kept.
# Examples:
# - Make font bold: $gui->change_font($widget, sub { $$_{-weight} = "bold" });
sub change_font
{
	my $self = shift;
	my ($widget, $change) = @_;

	#$Tkx::TRACE = 1;
	my $font = $widget->cget(-font);
	#print "$widget DIRECT FONT: '$font'\n";
	if (!$font)
	{
		if (my $style = $widget->cget(-style))
		{
			$font = Tkx::ttk__style_lookup($style, "-font");
			#print "$widget STYLE: '$font'\n";
		}
	}
	if (!$font)
	{
		if (my $class = Tkx::winfo("class", $widget))
		{
			$font = Tkx::ttk__style_lookup($class, "-font");
			#print "$widget CLASS: '$font'\n";
		}
	}
	if (!$font)
	{
		$font = "TkDefaultFont";
	}

	# Retrieve the font attributes as a hash
	my %attr = Tkx::SplitList(Tkx::font_actual($font));

	# Apply the change
	local $_ = \%attr;
	&$change;

	# Set the changed font (pass hash as array-ref for proper TCL quoting)
	$widget->configure(-font => [ %attr ]);
	#$Tkx::TRACE = 0;
}

# Add a separator and a menu-item if AddCancelMenuItem is true.
# This is convenient if the windowing system does not cancel a posted menu if
# one clicks outside.
sub add_cancel_menu_item
{
	my $self = shift;
	my ($menu) = @_;

	if ($self->{AddCancelMenuItem})
	{
		$menu->add_separator;
		$menu->add_command(-label => "Cancel Menu");
	}
}

# Convert an XPM to an image widget.
sub xpm2img
{
	my ($xpm) = @_;

	my $img = Tkx::widget->new(Tkx::image_create_photo());
	visit_pixels_xpm($xpm, sub {
		my ($x, $y, $color) = @_;
		if ($color ne "none")
		{
			$img->put($color, -to => ($x, $y));
		}
	});
	return $img;
}

# Get the x-coordinate for the specified index in the specified Entry control.
sub entry_get_x
{
	my $self = shift;
	my ($entry, $index) = @_;

	my ($x, $y, $w, $h) = Tkx::SplitList $entry->bbox($index);
	if ($index == $entry->index("end"))
	{
		# Cursor is at the end. Now bbox() has returned the coordinates
		# of the character *before* instead of the character after.
		# Correct this to make it more standard.
		($x, $w) = ($x + $w, 0);
	}
	return wantarray ? ( $x, $x + $w ) : $x;
}

# Get the numeric index for the specified x-coordinate in the specified Entry
# control.
sub entry_get_index
{
	my $self = shift;
	my ($entry, $x) = @_;

	return $entry->index("@" . $x);
}

# Get the current index for the specified Entry control.
sub entry_get_current_index
{
	my $self = shift;
	my ($entry) = @_;

	return $entry->index("insert");
}

# Focus the specified Entry control and set the insertion cursor if specified.
sub entry_focus
{
	my $self = shift;
	my ($entry, $icursor) = @_;

	$entry->g_focus();
	$entry->icursor($icursor) if defined $icursor;
}

# Deletes the contents in the selection range.
sub entry_delete_selection
{
	my $self = shift;
	my ($entry) = @_;

	$entry->delete("sel.first", "sel.last") if $entry->selection_present;
}

# Clear the selection tag
sub entry_clear_selection
{
	my $self = shift;
	my ($entry) = @_;

	$entry->selection_clear;
}

# Create the MainWindow.
sub CreateMainWin
{
	my $self = shift;

	$self->{MainWin} = my $mw = Tkx::widget->new(".");
	$mw->g_wm_title("TimeKeeper");
	$mw->g_grid_columnconfigure("0", -weight => 1);
	$mw->g_grid_rowconfigure("1", -weight => 1);  # middle area with timers
	TimeKeeper::ImgUtils::set_rgb_function sub { return $self->GetRgbRaw($_[0]) };

	$self->{ColorReadOnly} = $self->{ColorWindowBackground} = $mw->cget("-background");
	$self->{ColorEditable} = "white";

	if (my $geometry = get_geometry)
	{
		#sleep 2; print "Set initial geometry ($geometry)\n";
		$mw->g_wm_geometry($geometry);
		# The above command does set the size of the window correctly,
		# but the position not. The latter depends on the size of the
		# window frame and if the frame is taken into account or not.
		# Ubuntu has the same origin for geometry and rootx/y. Windows,
		# however, not. To work around this, check if the current
		# position is ok and if not, adjust with the difference (which
		# is the thickness of the frame).
		Tkx::update();  # update, so that rootx/rooty are updated as well
		#sleep 2;
		my @desired = geometry_pos $geometry;
		my @current = geometry_pos Tkx::winfo('geometry', $mw);
		#print "Resulting position: (@current)\n";
		my @adjust;
		$adjust[$_] = $desired[$_] - $current[$_] foreach 0..3;
		#print "Adjust position: (@adjust)\n";
		$mw->g_wm_geometry(get_geometry(@adjust));
		Tkx::update();  # update to prevent flickering
	}

	# Create the TopPanel
	($self->{TopPanel} = $mw->new_ttk__frame)->g_grid(-sticky => "ew");

	# Create the MiddlePanel which is scrollable
	# Create ScrolledWindow 'scrollbar manager'
	my $sw = $mw->new_ScrolledWindow(-scrollbar => "vertical", -sides => "ws");
	$sw->g_grid(-sticky => "nsew");
	# Create scrollable frame and put it in the ScrolledWindow
	my $sf = $sw->new_ScrollableFrame(-constrainedwidth => "yes");
	$sw->setwidget($sf);
	# Take internal Frame and make it into a Widget object.
	my $frm = Tkx::widget->new($sf->getframe());
	$frm->g_bind("<Destroy>", sub {
		set_scroll_pos $sf->yview;
	});
	# The mouse wheel is not working by default.
	my $middlePaneScroll = sub {
		my ($delta) = @_;

		$delta = sprintf "%.0f", ($delta / 120) * -3;  # convert to scroll units
		#info "Scroll $delta units\n";
		$sf->yview("scroll", $delta, "units");
	};
	# For Windows, use the <MouseWheel> event
	$mw->g_bind('<MouseWheel>' => [ $middlePaneScroll, Tkx::Ev("%D") ]);
	# For Linux, use the virtual mouse buttons 4 and 5
	$mw->g_bind('<Button-4>' => [ $middlePaneScroll, 120 ]);
	$mw->g_bind('<Button-5>' => [ $middlePaneScroll, -120 ]);

	# I haven't found a way (or event) to set the scroll position. The
	# only thing I found was using a timeout. The problem is that in order
	# to do this, the scrollbar must exist.
	#Tkx::after(1000, sub { $sf->yview(moveto => 0.25) });
	$self->{MiddlePanel} = $frm;

	# Create the BottomPanel
	($self->{BottomPanel} = $mw->new_ttk__frame)->g_grid(-sticky => "ew");

	# Record current position as it changes
	my ($currentGeometry, $geometryWriterTimerId);
	$mw->g_bind("<Configure>", sub {
		my $geometry = Tkx::winfo('geometry', $mw);
		if ($geometry ne $currentGeometry)
		{
			# Geometry has changed, record it
			#print "changed geometry=$geometry\n";
			# Cancel running timer; set new timer to save geometry
			Tkx::after_cancel($geometryWriterTimerId)
				if $geometryWriterTimerId;
			$geometryWriterTimerId = Tkx::after(500, sub {
				#print "set_geometry($geometry)\n";
				set_geometry $geometry;
			});

			$currentGeometry = $geometry;
		}
	});
}

# Create and set the Icons on the MainWin.
sub CreateIcons
{
	my $self = shift;

	my $mw = $self->GetMainWin;
	my $normalIcon32_data = $self->GetNormalIcon32XPM;

	my $normalIcon32 = xpm2img $normalIcon32_data;
	my $normalIcon16 = xpm2img downsample_xpm 2, 1, $normalIcon32_data;

	# Create a reddish icon for the stopped status
	my $stoppedIcon32_data =
		replace_color_xpm {
			"#FFFFFF" => "#FFBBBB",
			"#FFFF00" => "#FF3300",
			"#000000" => "#CC0000",
		},
		$normalIcon32_data;
	my $stoppedIcon32 = xpm2img $stoppedIcon32_data;
	my $stoppedIcon16 = xpm2img downsample_xpm 2, 1, $stoppedIcon32_data;

	# Set the MainWindow icons
	$self->{NormalIcons} = [ $normalIcon32, $normalIcon16 ];
	$self->{StoppedIcons} = [ $stoppedIcon32, $stoppedIcon16 ];
	$mw->g_wm_iconphoto($normalIcon32, $normalIcon16);
}

# Create the MainMenu on the MainWin.
sub CreateMainMenu
{
	my $self = shift;

	my $mw = $self->GetMainWin;
	my $frm = $self->GetTopPanel;

	# Create copyright label
	$self->{CopyRightLabel} = my $copyRightLabel =
		$frm->new_ttk__label(-text => "(C) AGB 2001+", -foreground => "#EECC00");
	$copyRightLabel->g_pack(-side => "left");
	$copyRightLabel->g_bind("<Enter>", sub { $copyRightLabel->configure(-relief => "raised") });
	$copyRightLabel->g_bind("<Leave>", sub { $copyRightLabel->configure(-relief => "flat") });
	$copyRightLabel->g_bind("<ButtonPress-1>", sub { $copyRightLabel->configure(-relief => "sunken") });
	$copyRightLabel->g_bind("<ButtonRelease-1>", sub { $copyRightLabel->configure(-relief => "raised"); EvtStartStop });

	# Create the main menu
	my $mainmenu = $copyRightLabel->new_menu(-tearoff => 0);
	$mainmenu->add_command(-label => "Pause/Resume", -command => [ \&EvtStartStop ]);
	$mainmenu->add_command(-label => "Reset All", -command => [ \&EvtResetTimer, "all" ]);
	$mainmenu->add_separator;
	$mainmenu->add_command(-label => "Generate Log", -command => [ \&EvtGenerateLog, "default" ]);
	my @alt_logs = get_alt_logs;
	if (@alt_logs > 0)
	{
		my $mnuAltLogs = $mainmenu->new_menu(-tearoff => 0);
		$mainmenu->add_cascade(-label => "Alternative Logs", -menu => $mnuAltLogs);
		foreach (@alt_logs)
		{
			$mnuAltLogs->add_command(-label => $_, -command => [ \&EvtGenerateLog, $_ ]);
		}
	}
	$mainmenu->add_command(-label => "Define Log", -command => [ \&EvtDefineLog ]);
	$mainmenu->add_command(-label => "Define Timer Groups", -command => [ \&EvtEditGroups]);
	foreach my $target (qw/editor clipboard/)
	{
		my $status = is_generate_log_target $target;
		$mainmenu->add_checkbutton(-label => "Generate Log to \u$target", -variable => \$status, -command => [ \&EvtSetGenerateTarget, $target, \$status ]);
	}
	$mainmenu->add_separator;
	my @tools = get_exttool_entries;
	if (@tools > 0)
	{
		# There are tools, create a submenu
		my $mnuTools = $mainmenu->new_menu(-tearoff => 0);
		$mainmenu->add_cascade(-label => "Tools", -menu => $mnuTools);
		foreach my $entry (@tools)
		{
			my ($text, $command) = @$entry;
			if ($text eq "---")
			{
				$mnuTools->add_separator;
			}
			else
			{
				$mnuTools->add_command(-label => $text, -command => sub { system $command });
			}
		}
		$mainmenu->add_separator;
	}
	$mainmenu->add_command(-label => "Configuration", -command => [ \&EvtEditConfig ]);
	my $clockFormats = $self->{ClockFormats};
	if ($clockFormats && @$clockFormats > 1)
	{
		my $clockFormat = $self->{ClockFormatRef};
		my $mnuClockFormat = $mainmenu->new_menu(-tearoff => 1);
		$mainmenu->add_cascade(-label => "Clock Format", -menu => $mnuClockFormat);
		foreach my $cf (0..@$clockFormats-1)
		{
			my $format = $$clockFormats[$cf];
			$mnuClockFormat->add_radiobutton(-label => $format, -variable => $clockFormat, -value => $cf, -command => \&EvtRedrawWallTime);
		}
	}
	$mainmenu->add_command(-label => "Edit Events", -command => [ \&EvtEditEvents ]);
	$mainmenu->add_separator;
	$mainmenu->add_command(-label => "Quit & Keep timing", -command => sub { set_keep_running_status 1; $mw->g_destroy });
	$mainmenu->add_command(-label => "Exit", -command => sub { $mw->g_destroy });
	$self->add_cancel_menu_item($mainmenu);
	$copyRightLabel->g_bind("<Button-3>", [ sub { $self->ShowPopup($mainmenu, @_) }, Tkx::Ev("%W %x %y") ]);
	$copyRightLabel->g_tooltip__tooltip("Click to pause/resume\nRightclick for menu");
	$self->change_font($copyRightLabel, sub { $$_{-weight} = "bold" });
}

# Create the Clock on the MainWin.
sub CreateWallClock
{
	my $self = shift;

	my $frm = $self->GetTopPanel;

	# Create WallClock (label with current time)
	$self->{LblClock} = my $lblClock = $frm->new_ttk__label;
	$lblClock->g_pack(-side => "right");
	$self->change_font($lblClock, sub { $$_{-weight} = "normal" });

	# Create menu for clock
	my $clockFormats = $self->{ClockFormats};
	if ($clockFormats && @$clockFormats > 1)
	{
		my $clockmenu = $lblClock->new_menu(-tearoff => 0);
		my $clockFormat = $self->{ClockFormatRef};
		my $mnuClockFormat = $clockmenu->new_menu(-tearoff => 1);
		$clockmenu->add_cascade(-label => "Clock Format", -menu => $mnuClockFormat);
		foreach my $cf (0..@$clockFormats-1)
		{
			my $format = $$clockFormats[$cf];
			$mnuClockFormat->add_radiobutton(-label => $format, -variable => $clockFormat, -value => $cf, -command => \&EvtRedrawWallTime);
		}
		$self->add_cancel_menu_item($clockmenu);

		$lblClock->g_bind("<Button-3>", [ sub { $self->ShowPopup($clockmenu, @_) }, Tkx::Ev("%W %x %y") ]);

		$lblClock->g_bind("<Double-Button-1>", \&EvtCycleClockFormat);
	}
}

# Create form with the widgets for one timer. This form is created at the top
# of the $parent_widget. The timer widgets are also added to the @Timers
# data structure.
sub CreateTimer
{
	my $self = shift;
	my ($parent_widget, $timer_id) = @_;

	my $colorEditable = $self->{ColorEditable};
	my $colorReadOnly = $self->{ColorReadOnly};

	my $frm = $parent_widget->new_ttk__frame;
	$frm->g_pack(-side => "top", -fill => "x");
	$frm->g_grid_columnconfigure("1", -weight => 1);  # middle area

	# number label
	my $label = $frm->new_ttk__label(-text => $timer_id, -width => 2, -anchor => "e");
	$label->g_grid(-row => 0, -column => 0);
	# Retrieve group-info of this timer and set the background color
	my $groupname = get_timer_current_group_name $timer_id;
	my $group = get_timer_group_info $groupname;
	if ($group)
	{
		my $groupcolor = $$group{color};
		if ($groupcolor)
		{
			my $grouptextcolor = $self->GetTextColorForBackground($groupcolor);
			$label->configure(-background => $groupcolor, -foreground => $grouptextcolor);
		}
		#info "Create Timer $timer_id with group $groupname and color $groupcolor\n";
	}
	my $popupGroupsMenu = sub {
		my $menu = $label->new_menu(-tearoff => 0);
		$menu->add_radiobutton(-label => "<None>", -variable => \$groupname, -value => "", -command => [ \&EvtSetTimerGroup, $timer_id, "" ]);
		my $groups = get_timer_group_infos;
		if ($groups && @$groups)
		{
			# There are groups, add them to the menu
			foreach my $group (@$groups)
			{
				my $name = $$group{name};
				$menu->add_radiobutton(-label => $name, -variable => \$groupname, -value => $name, -command => [ \&EvtSetTimerGroup, $timer_id, $name ]);
				if (my $color = $$group{color})
				{
					my $textcolor = $self->GetTextColorForBackground($color);
					$menu->entryconfigure("last", -background => $color, -foreground => $textcolor, -selectcolor => $textcolor);
				}
			}
			$menu->add_separator;
		}
		# Add option to edit groups
		$menu->add_command(-label => "Edit Groups", -command => [ \&EvtEditGroups]);
		$self->add_cancel_menu_item($menu);
		$self->ShowPopup($menu, @_);
	};
	# Add the bindings
	$label->g_bind("<Button-3>", [ $popupGroupsMenu, Tkx::Ev("%W %x %y") ]);
	$label->g_tooltip__tooltip("Rightclick to change group");

	# description field
	my $text = get_timer_current_description $timer_id;
	my $descr = $frm->new_entry(-textvariable => \$text, -validate => "all", -validatecommand => [ sub { EvtEditDescription $timer_id, @_ }, Tkx::Ev("%P") ], -background => $colorEditable);
	$descr->g_grid(-row => 0, -column => 1, -sticky => "nswe");
	$self->{DefaultInsertOnTime} = $descr->cget("-insertontime");

	# time field
	my $timetext = format_time get_timer_current_time $timer_id;
	my $time = $frm->new_entry(-textvariable => \$timetext, -width => "8", -justify => "right", -background => $colorReadOnly, -cursor => "arrow", -insertontime => "0");
	$time->g_grid(-row => 0, -column => 2, -sticky => "nswe");
	$time->g_bind("<Button-1>", sub { EvtActivate $timer_id });
	my $menu = $time->new_menu(-tearoff => 0);
	$menu->add_command(-label => "Activate", -command => sub { EvtActivate $timer_id });
	$menu->add_command(-label => "Reset", -command => [ \&EvtResetTimer, $timer_id ]);
	$menu->add_command(-label => "Reset All", -command => [ \&EvtResetTimer, "all" ]);
	$menu->add_separator;
	my %mniTransfer;  # items to remember about the menuitem Transfer
	$mniTransfer{mode} = "transfer";
	$menu->add_command(-label => "<transfer>", -command => sub { EvtEditTimer($timer_id, $mniTransfer{mode}) });
	$mniTransfer{index} = $menu->index("last");
	my $mnuTimeEdit = $menu->new_menu(-tearoff => 0);
	$menu->add_cascade(-label => "Edit", -menu => $mnuTimeEdit);
	$mnuTimeEdit->add_command(-label => "Increase", -command => [ \&EvtEditTimer, $timer_id, "inc" ]);
	$mnuTimeEdit->add_command(-label => "Decrease", -command => [ \&EvtEditTimer, $timer_id, "dec" ]);
	$mnuTimeEdit->add_command(-label => "Edit", -command => [ \&EvtEditTimer, $timer_id, "edit" ]);
	$self->add_cancel_menu_item($menu);
	my $popupTimeMenu = sub {
		my ($label, $mode);
		if (get_active == $timer_id)
		{
			$label = "Take from Previous";
			$mode = "take";
		}
		else
		{
			$label = "Transfer to Active";
			$mode = "transfer";
		}
		$menu->entryconfigure($mniTransfer{index}, -label => $label);
		$mniTransfer{mode} = $mode;
		$self->ShowPopup($menu, @_);
	};
	$time->g_bind("<Button-3>", [ $popupTimeMenu, Tkx::Ev("%W %x %y") ]);
	$time->g_tooltip__tooltip("Click to activate\nRightclick for menu");

	# Add event to go to next timer description on arrow-up/down
	$descr->g_bind("<Down>", sub { $self->FocusNextDescription($timer_id, 1) });
	$descr->g_bind("<Up>", sub { $self->FocusNextDescription($timer_id, -1) });

	# Add widgets to data structure
	$self->{Timers}[$timer_id] = {
		labelctrl => $label,
		groupname => \$groupname,
		descrctrl => $descr,
		descrtext => \$text,
		timectrl  => $time,
		timetext  => \$timetext,
	};
}


1;


