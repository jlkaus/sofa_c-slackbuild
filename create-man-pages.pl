#!/usr/bin/perl

use strict;
use warnings;

my $header_file = shift;
my $macro_files_list = shift;
my $manual_file = shift;
my $PRGNAM = shift;
my $VERSION = shift;
my $MANUAL = shift;
my $DEST = shift;


sub check_brackets {
    my ($s, $l, $r) = @_;
    my $lct = 0;
    my $rct = 0;

    for(my $i = 0; $i < length $s; ++$i) {
        my $c = substr($s, $i, 1);
        if($c eq $l) {
            ++$lct;
        } elsif($c eq $r) {
            ++$rct;
        }
    }

    if($lct == $rct) {
        # All brackets match up
        return 1;
    } elsif($lct > $rct) {
        # More left brackets than right... keep going.
        return undef;
    } else {
        # More right brackets than left... shouldn't be possible, but we might not be scanning proper code.
        return undef;
        #        die "ERROR: Too many $r brackets precede $l brackets in: $s\n";
    }
}



# Read in the header_file to find the list of methods to create man pages for.
# Send it through the pre-processor first though to eliminate comments, etc.
my $macro_files_options = join(' ',map { "-imacros $_" } (split / /,$macro_files_list));
my $cur_stmt = "";
my $cur_stmt_broken = "";
my %functions = ();
foreach(`cpp -I /usr/include $macro_files_options -P $header_file`) {
    chomp;
    if(/^\s*$/) {
        # ignore empty line
    } elsif(/^\s*(.*?)\s*$/) {
        if($cur_stmt_broken ne "") {
            $cur_stmt_broken .= "\n";
        }
        $cur_stmt_broken .= $_;
        $cur_stmt .= " ".$1;

        # Analyze the current statement to see if it is complete.
        # Complete statements:
        #   - End in a ;
        #   - may contain complete matched sets of {} braces.
        #   - may contain complete matched sets of () braces.
        #   - may contain complete matched sets of [] braces.
        # Note we'll be ignoring double quotes, single quotes, and escaping.
        # That is, if a string/character contains a brace, we will miscount.
        # Likewise, if a brace is escaped somewhere, in a context that would
        # make it not act as a brace at all, we will miscount.
        if($cur_stmt =~ /;\s*$/ && check_brackets($cur_stmt, "{", "}") && check_brackets($cur_stmt, "(", ")") && check_brackets($cur_stmt, "[","]")) {
            # Statement looks complete.  Is it a function prototype?
            if($cur_stmt =~ /^ (.+?)\s+([^\s(]+)\s*\((.*)\)\s*;\s*$/) {
                my ($ret, $name, $args) = ($1, $2, $3);
                $ret =~ s/^\s*//;
                $ret =~ s/\s*$//;
                $args =~ s/^\s*//;
                $args =~ s/\s*$//;
                if(defined $functions{$name}) {
                    die "ERROR: Redefinition of $name\n";
                }
                $functions{$name} = {name=>$name, ret=>$ret, args=>$args, proto=>"$ret $name($args)", orig=>$cur_stmt_broken};
            }

            $cur_stmt = "";
            $cur_stmt_broken = "";
        }
    } else {
        die "What? [$_]\n";
    }
}

die "ERROR: Incomplete statement at end of header file: $cur_stmt\n" if $cur_stmt;



# Ok, now parse the manual.lis file.
# In each page, look for the first non-empty, left justified line.  Parse it as a function prototype, and compare
# to the ones we've saved.
open(my $mfh, "<", $manual_file) or die "ERROR: Unable to open $manual_file for reading.\n";
my $skip_page = undef;
my $found_proto = undef;
my $doc_block = undef;
my $in_routine_block = undef;
$cur_stmt = "";
my %sdescs = ();
my $pc = 0;
my $fc = 0;
while(<$mfh>) {
    chomp;
    if($_ eq "\f") {
        ++$pc;
        $skip_page = undef;
        $found_proto = undef;
        $in_routine_block = undef;
        $cur_stmt = "";
        $doc_block = undef;
    } elsif($skip_page) {
        # I guess look for routines or operations.
        if(!defined $in_routine_block) {
            if(/^ROUTINES$/ || /^OPERATIONS /) {
                $in_routine_block = 1;
            }
        } else {
            if(/^CALLS:/) {
                $in_routine_block = undef;
            } else {
                if(/^     ([A-Z0-9]+)\s*(.*)$/) {
                    if(defined $sdescs{$1}) {
                        print "WARN: Found duplicate short description for routine $1\n";
                    } else {
                        $sdescs{$1} = $2;
                    }
                }
            }
        }
    } elsif($found_proto) {
        # This page contains a function definition in its first line,
        # so make a man page out of it.

        if(!defined $doc_block && /^\s*\/\*\+?\s*$/) {
            $doc_block = "";
        } elsif(defined $doc_block && /^\s*\*\/\s*$/) {
            # Done collecting documentation for this function.  Skip the rest of the page.
            $found_proto->{doc} = $doc_block;
            $skip_page = 1;
        } elsif(defined $doc_block && /^\s*\*\*?\s*$/) {
            # empty line in the docs.
            $doc_block .= "\n";
        } elsif(defined $doc_block && /^\s*\*\*?  ?(.*)$/) {
            # non-empty line in the docs.
            $doc_block .= $1."\n";
        } else {
            die "ERROR: Looking for documentation lines for $found_proto->{name}, but got non-documenation line: $_\n";
        }
    } else {
        # Not skipping this page, and still looking for a prototype
        if(/^\s*$/) {
            # Skip blanks at the top.
        } elsif(/^\s*(.*?)\s*$/) {
            $cur_stmt .= " ".$1;

            # See if we have enough brackets to make a complete statement... Don't look for semicolons though.
            if(check_brackets($cur_stmt, "{", "}") && check_brackets($cur_stmt, "(", ")") && check_brackets($cur_stmt, "[","]")) {
                # Looks like its probably a complete statement.  Parse as a function prototype...
                if($cur_stmt =~ /^ (.+?)\s+([^\s(]+)\s*\((.*)\)\s*$/) {
                    my ($ret, $name, $args) = ($1, $2, $3);
                    $ret =~ s/^\s*//;
                    $ret =~ s/\s*$//;
                    $args =~ s/^\s*//;
                    $args =~ s/\s*$//;
                    if(!defined $functions{$name}) {
                        die "ERROR: Found a page for a function we don't know about: $name\n";
                    } else {
                        if($ret ne $functions{$name}->{ret}) {
                            print "ERROR: Function page for $name has mismatched return type $ret vs $functions{$name}->{ret}\n";
                        }
                        if($args ne $functions{$name}->{args}) {
                            print "WARN: Function page for $name has mismatched argument list $args vs $functions{$name}->{args}\n";
                        }
                        $found_proto = $functions{$name};
                        ++$fc;
                    }
                } else {
                    # Doesn't parse as a function.. That's ok, just skip this page.
                    $skip_page = 1;
                }
            } else {
                # Not a valid statement yet.  That's fine, just keep adding lines for now...
            }
        }
    }
}
close($mfh);
#print "$pc $fc\n";

foreach(sort keys %functions) {
    my $n = $_;
    if(!defined $functions{$n}->{doc}) {
        die "ERROR: Function $n has no documentation defined.\n";
    }
#    print "\n$n:\n";
    # Now we need to actual generate a man page for this thing....
    # For now, break up the docs more to get out:
    # short description
    # long description
    # status
    # givens
    # arg returns
    # function returns
    # notes
    # references
    # calleds
    # copyright
    # sofa release
    # last revision
    my $seek = 0;
    my $section = undef;
    my $osection = "";
    my @doc_lines = split /\n/, $functions{$n}->{doc};
    $functions{$n}->{notes} = "";
    foreach(@doc_lines) {
        if($seek < 3 && /^- [ -]*$/) {
            ++$seek;
        } elsif($seek == 1 && /^ [[:alnum:] ]+$/) {
            ++$seek;
        } elsif($seek == 3) {
            if(!defined $section && /^\s*$/) {
                # ignore blank, but now looking at sdesc
                $section = "ldesc";
                $functions{$n}->{ldesc} = "";
            } else {
                if(/^Status:\s+(.*)$/) {
                    $functions{$n}->{status} = $1;
                } elsif(/^Given:/) {
                    $section = "given";
                    $functions{$n}->{given} = "";
                } elsif(/^Given (\(.*\)):\s*$/) {
                    $section = "given";
                    $functions{$n}->{given} = "";
                    $functions{$n}->{given_extra} = $1;
                } elsif(/^Called:/) {
                    $section = "called";
                    $functions{$n}->{called} = "";
                } elsif(/^Returned +\(function value\):\s*$/) {
                    $section = "returned_fv";
                    $functions{$n}->{returned_fv} = "";
                } elsif(/^Returned:/) {
                    $section = "returned";
                    $functions{$n}->{returned} = "";
                } elsif(/^Given and returned:/) {
                    $section = "give_return";
                    $functions{$n}->{given_return} = "";
                } elsif(/^Returned (\(.*\)):\s*$/) {
                    $section = "returned";
                    $functions{$n}->{returned} = "";
                    $functions{$n}->{returned_extra} = $1;
                } elsif(/^References?:/) {
                    $section = "refs";
                    $functions{$n}->{refs} = "";
                } elsif(/^Defined in (.*):\s*$/) {
                    $section = "defined";
                    $functions{$n}->{defined} = $1."\n";
                } elsif(/^Last revision:\s*(.*)$/) {
                    $functions{$n}->{last_rev} = $1;
                } elsif(/^Copyright \(C\)\s*.*$/) {
                    $functions{$n}->{copyright} = $_;
                } elsif(/^Note:\s*$/) {
                    $section = "note";
                    $functions{$n}->{note} = "";
                } elsif(/^Notes:\s*$/) {
                    $section = "notes";
                } elsif($section eq "notes" && /^   ?(.*)$/) {
                    $functions{$n}->{$section} .= $_."\n";
                } elsif(/^   ?(.*)$/) {
                    $functions{$n}->{$section} .= $1."\n";
                } elsif(/^\s*$/) {
                    $functions{$n}->{$section} .= "\n";
                } elsif($section eq "notes" && /^([[:digit:]]+\)\s+.*)$/) {
                    $functions{$n}->{$section} .= $1."\n";
                } elsif($section eq "refs" && /^[[:digit:]]+\)\s+(.*)$/) {
                    $functions{$n}->{$section} .= $1."\n";
                } elsif(/^([[:digit:]]+\)\s+.*)$/) {
                    print "WARN: Notes found outside Notes section... starting notes section. $n\n";
                    $section = "notes";
                    $functions{$n}->{$section} .= $1."\n";
                } elsif($section eq "ldesc") {
                    $functions{$n}->{$section} .= $_."\n";
                } else {
                    print "WARN: For function $n, ignoring extraneous line in section $section: [$_]\n";
                }
            }
        }

        if(defined $section && $section ne $osection) {
#            print "$n: Found start of section $section\n";
            $osection = $section;
        }
    }

    my $hname = $header_file;
    $hname =~ s/^(.*)\///;
    my $bdate = `date -u +%F`;
    chomp $bdate;

    my $mnfn = $DEST."/$n.3";
    open(my $mnfh, ">", $mnfn) or die "ERROR: Unable to open $mnfn for writing.\n";

    # Then, re-assemble as a man page:
    my $f = $functions{$n};
    my $r = uc $n;
    $r =~ s/^IAU//;
    if(defined $sdescs{$r}) {
        $f->{sdesc} = $sdescs{$r};
    } else {
        print "WARN: Routine $n doesn't have a short description.\n";
        $f->{sdesc} = "";
    }

    print $mnfh ".TH $f->{name} 3 \"$bdate\" \"$PRGNAM $VERSION\" \"$MANUAL\"\n";
    print $mnfh ".SH NAME\n";
    print $mnfh "$f->{name} \- $f->{sdesc}\n";
    print $mnfh ".SH SYNOPSIS\n";
    print $mnfh ".nf\n";
    print $mnfh ".B #include <$hname>\n";
    print $mnfh ".PP\n";
    print $mnfh gen_synopsis($f->{ret}, $f->{name}, $f->{args}, $f->{orig});
    print $mnfh ".fi\n";
#    print $mnfh "$f->{orig}\n";
    print $mnfh ".SH DESCRIPTION\n";
    print $mnfh "$f->{ldesc}\n";
    print $mnfh ".SS Status\n$f->{status}\n" if defined $f->{status};
    print $mnfh gen_given_return($f->{given}, $f->{give_return}, $f->{returned}, $f->{given_extra}, $f->{returned_extra},$f->{name});
    print $mnfh gen_return_value($f->{returned_fv});

    if(defined $f->{notes} || defined $f->{note} || defined $f->{refs} || defined $f->{defined} || defined $f->{last_rev} || defined $f->{called}) {
        print $mnfh ".SH NOTES\n";
        print $mnfh gen_notes($f->{note}, $f->{notes}, $f->{name});
        print $mnfh gen_called($f->{called});
        print $mnfh gen_defined($f->{defined});
        print $mnfh gen_refs($f->{refs}, $f->{name});
        print $mnfh gen_last_rev($f->{last_rev});
    }
    if(defined $f->{copyright}) {
        print $mnfh ".SH COPYRIGHT\n";
        print $mnfh "$f->{copyright}\n";
    }

    close($mnfh);
}

sub gen_synopsis {
    my ($r, $n, $a, $o) = @_;

    # all bold, except the arg names
    my $prefix = "$r $n(";
    my $suffix = ");";
    my $blanks = " " x (length $prefix);
    my $arg_max_size = 81 - 7 - (length $prefix) - 2 - 1;
    my @args = split /,/,$a;
    my @arg_data = ();
    my $cur_line = ".B \"$prefix";
    my $cur_size = 0;
    my $first = 1;
    foreach(@args) {
        s/^\s*//;
        my $t1 = "";
        my $an = "";
        my $t2 = "";
        if(/^(.*?)\s*([[:alnum:]_]+)(\[[[:digit:]\[\]]*\])$/) {
            ($t1, $an, $t2) = ($1, $2, $3);
        } elsif(/^(.*?)\s*([[:alnum:]_]+)$/) {
            ($t1, $an, $t2) = ($1, $2, "");
        }

        my $clen = length ($t1 . " " . $an . $t2);
        if(substr($t1, -1, 1) eq "*") {
            $clen -= 1;
        }
        if(!$first) {
            $clen += 2;
        }
        if($cur_size + $clen > $arg_max_size) {
            # won't fit here. End the current line and start a new one.
            if(!$first) {
                $cur_line .= ",";
            }
            $clen -= 2;
            $cur_size = $clen;
            push @arg_data, $cur_line;
            $cur_line = ".B \"$blanks";
        } else {
            # Should fit on this line, so add it on.
            if(!$first) {
                $cur_line .= ", ";
            }
            $cur_size += $clen;
        }
        my $tas = substr($t1, -1, 1) eq "*" ? "":" ";
        $cur_line .= $t1 . $tas. "\\fI".$an."\\fB".$t2;

        $first = undef;
    }
    $cur_line .= $suffix;
    push @arg_data, $cur_line;

    my @orig_lines = split /\n/, $o;
    my $sl = scalar @arg_data;
    my $ol = scalar @orig_lines;

    print "WARN: $n synopsis lines $ol -> $sl\n" if $sl != $ol;
    my $rv = "";
    foreach(@arg_data) {
        $rv .= "$_\"\n";
    }

    return $rv;
}

sub gen_given_return {
    my ($g, $gr, $r, $ge, $re, $i) = @_;

    my $rv = "";
    if(defined $g) {
        $rv .= ".SS Given\n";
        $rv .= "$ge\n.br\n" if defined $ge;
        $rv .= gen_parms($g);
    }
    if(defined $gr) {
        $rv .= ".SS Given and Returned\n";
        $rv .= gen_parms($gr);
    }
    if(defined $r) {
        $rv .= ".SS Returned\n";
        $rv .= "$re\n.br\n" if defined $re;
        $rv .= gen_parms($r);
    }

    return $rv;
}

sub gen_parms {
    my ($p) = @_;
    my $rv = "";

    my @ln = split /\n/, $p;
    foreach(@ln) {
        if(/^( ?[[:alnum:]_,]+)(\s+)([^\s]+)(\s+.*)$/) {
            my ($vs, $sp, $ty, $de) = ($1, $2, $3, $4);

            $vs =~ s/,/\\fR,\\fI/g;
            $rv .= "\\fI$vs\\fR$sp\\fB$ty\\fR$de\n.br\n";
        } else {
            $rv .= $_."\n.br\n";
        }
    }
    return $rv;
}

sub gen_return_value {
    my ($rfv) = @_;

    if(defined $rfv) {
        my $rv = ".SH RETURN VALUE\n";
        $rfv =~ s/^(\s*)([^\s]+)(\s*)/$1\\fB$2\\fR$3/;
        $rv .= $rfv;

        return $rv
    } else {
        return "";
    }
}

sub gen_notes {
    my ($n, $ns, $i) = @_;
    if(defined $n && $ns ne "") {
        die "ERROR: Note and Notes specified. $i\n";
    }
    if(defined $n) {
        return $n;
    }

    if($ns ne "") {
        ##@TODO: Parse out the note list to make proper .IP x i lists? Might be difficult to keep the proper
        # spacing and lineation.  Seems to look OK if I just let it be.
        return $ns;
#        print "*** $i Notes:\n";
#        print "$ns\n";
    } else {
        return "";
    }
}

sub gen_called {
    my ($c) = @_;
    if(defined $c) {
        my $rv = ".SS Called\n";
        foreach(split /\n/, $c) {
            my ($n, $desc) = split / /, $_, 2;
            $rv .= ".BR \"$n\" \"$desc\"\n.br\n";
        }
        return $rv;
    } else {
        return "";
    }
}
sub gen_defined {
    my ($d) = @_;
    if(defined $d) {
        my @dl = split /\n/, $d;
        my $in = shift @dl;
        my $rv = ".SS Defined in \\fB$in\\fR\n";
        foreach(@dl) {
            my ($n, $desc) = split / /,$_, 2;
            $rv .= ".BR \"$n\" \"$desc\"\n.br\n";
        }
        return $rv;
    } else {
        return "";
    }
}
sub gen_refs {
    my ($r, $i) = @_;
    if(defined $r) {
        my $rv = ".SS References\n";
        $rv .= $r;

        return $rv;
    } else {
        return "";
    }
}

sub gen_last_rev {
    my ($lr) = @_;
    if(defined $lr) {
        my $rv = ".SS Last revision\n";
        $rv .= "$lr\n";
        return $rv;
    } else {
        return "";
    }
}
