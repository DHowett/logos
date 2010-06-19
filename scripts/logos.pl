#!/usr/bin/env perl

use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Logos::Method;
use Logos::Group;
use Logos::StaticClassGroup;
use Logos::Subclass;

$filename = $ARGV[0];
die "Syntax: $FindBin::Script filename\n" if !$filename;
open(FILE, $filename) or die "Could not open $filename.\n";

my @inputlines = ();
my $readignore = 0;
my $built = "";
my $building = 0;
READLOOP: while($line = <FILE>) {
	chomp($line);

	# End of a multi-line comment while ignoring input.
	if($readignore && $line =~ /^.*?\*\/\s*/) {
		$readignore = 0;
		$line = $';
	}
	if($readignore) { push(@inputlines, ""); next; }

	my @quotes = quotes($line);

	# Delete all single-line to-EOL // xxx comments.
	while($line =~ /\/\//g) {
		next if fallsBetween($-[0], @quotes);
		$line = $`;
		redo READLOOP;
	}

	# Delete all single-line /* xxx */ comments.
	while($line =~ /\/\*.*?\*\//g) {
		next if fallsBetween($-[0], @quotes);
		$line = $`.$';
		redo READLOOP;
	}
	
	# Start of a multi-line /* comment.
	while($line =~ /\/\*.*$/g) {
		next if fallsBetween($-[0], @quotes);
		$line = $`;
		push(@inputlines, $line);
		$readignore = 1;
		next READLOOP;
	}

	if(!$readignore) {
		# Line starts with - (return), start gluing lines together until we find a { or ;...
		if(!$building && $line =~ /^\s*(%new.*?)?\s*([+-])\s*\(\s*(.*?)\s*\)/ && index($line, "{") == -1 && index($line, ";") == -1) {
			$building = 1;
			$built = $line;
			push(@inputlines, "");
			next;
		} elsif($building) {
			$built .= " ".$line;
			if(index($line,"{") != -1 || index($line,";") != -1) {
				push(@inputlines, $built);
				$building = 0;
				$built = "";
				next;
			}
			push(@inputlines, "");
			next;
		}
		push(@inputlines, $line) if !$readignore;
	}
}

close(FILE);

@outputlines = ();
$lineno = 1;

$firsthookline = -1;
$ctorline = -1;

my $defaultGroup = Group->new();
$defaultGroup->name("_ungrouped");
$defaultGroup->explicit(0);
@groups = ($defaultGroup);

my $staticClassGroup = StaticClassGroup->new();
%classes = ();

$hassubstrateh = 0;
$ignore = 0;

my @nestingstack = ();
my $inclass = 0;
my $last_blockopen = -1;
my $lastInitLine = -1;
my $curGroup = $defaultGroup;
my $lastMethod;

my $isNewMethod = undef;

foreach $line (@inputlines) {
	# Search for a discrete %x% or an open-ended %x (or %x with a { or ; after it)
	if($line =~ /\s*#\s*include\s*[<"]substrate\.h[">]/) {
		$hassubstrateh = 1;
	} elsif($line =~ /^\s*#\s*if\s*0\s*$/) {
		$ignore = 1;
	} elsif($ignore == 1 && $line =~ /^\s*#\s*endif/) {
		$ignore = 0;
	} elsif($ignore == 0) {
		# %hook name
		my $matched = 0;
		
		# The Big Scanning Loop
		# Why is it this way? Why a giant loop with a bunch of small loops inside ending with redo?
		# Merely so I could use /g global searches for each command type and auto-skip ones in quotes.
		# Without /g, I'd process the same one over and over. /g only makes sense in a loop.
		#
		# We don't want to process in-order, either, so %group %thing %end won't kill itself automatically
		# because it found a %end with the %group. This allows things to proceed out-of-order:
		# we re-start the scan loop every time we find a match so that the commands don't need to
		# be in the processed order on every line. That would be pointless.
		SCANLOOP: while(1) {
			@quotes = quotes($line);

			# %hook at the beginning of a line after any amount of space
			while($line =~ /^\s*%(hook)\s+([\$_\w]+)/g) {
				next if fallsBetween($-[0], @quotes);

				nestingMustNotContain($lineno, "%$1", \@nestingstack, "hook", "subclass");

				$firsthookline = $lineno if $firsthookline == -1;

				nestPush($1, $lineno, \@nestingstack);

				$class = $curGroup->addClassNamed($2);
				$inclass = 1;
				$line = $';

				redo SCANLOOP;
			}

			while($line =~ /^\s*%(subclass)\s+([\$_\w]+)\s*:\s*([\$_\w]+)\s*(\<\s*(.*?)\s*\>)?/g) {
				next if fallsBetween($-[0], @quotes);

				nestingMustNotContain($lineno, "%$1", \@nestingstack, "hook", "subclass");

				$firsthookline = $lineno if $firsthookline == -1;

				nestPush($1, $lineno, \@nestingstack);

				my $classname = $2;
				$class = Subclass->new();
				$class->name($classname);
				$class->superclass($3);
				if(defined($4) && defined($5)) {
					my @protocols = split(/\s*,\s*/, $5);
					foreach(@protocols) {
						$curGroup->addProtocol($_);
					}
				}
				$curGroup->addClass($class);

				$staticClassGroup->addDeclaredOnlyClass($classname);
				$classes{$classname}++;

				$inclass = 1;
				$line = $';

				redo SCANLOOP;
			}

			# %group at the beginning of a line after any amount of space
			while($line =~ /^\s*%(group)\s+([\$_\w]+)/g) {
				next if fallsBetween($-[0], @quotes);

				nestingMustNotContain($lineno, "%$1", \@nestingstack, "group");
				nestPush($1, $lineno, \@nestingstack);
				$line = $`.$';

				$curGroup = getGroup($2);
				if(!defined($curGroup)) {
					$curGroup = Group->new();
					$curGroup->name($2);
					push(@groups, $curGroup);
				}

				redo SCANLOOP;
			}
			
			# %group at the beginning of a line after any amount of space
			while($line =~ /^\s*%(class)\s+([+-])?([\$_\w]+)/g) {
				next if fallsBetween($-[0], @quotes);

				# TODO: This will cause a constructor if you use %class but not %hook (blank constructor)
				# Not a really big deal, but still nice to fix. Maybe with a list of patchups instead of
				# "put this hre."
				$firsthookline = $lineno if $firsthookline == -1;

				my $scope = $2;
				$scope = "-" if !$scope;
				my $classname = $3;
				if($scope eq "+") {
					$staticClassGroup->addUsedMetaClass($classname);
				} else {
					$staticClassGroup->addUsedClass($classname);
				}
				$classes{$classname}++;
				$line = $`.$';

				redo SCANLOOP;
			}
			
			# %new(type) at the beginning of a line after any amount of space
			while($line =~ /^\s*%new(\((.*?)\))?(%?)(?=\W?)/g) {
				next if fallsBetween($-[0], @quotes);

				nestingMustContain($lineno, "%new", \@nestingstack, "hook", "subclass");
				my $xtype = "v\@:";
				$xtype = $2 if $2;
				fileWarning($lineno, "%new without a type specifier, assuming v\@: (void return, id and SEL args)") if !$2;
				$isNewMethod = $xtype;
				$line = $`.$';

				redo SCANLOOP;
			}
			
			# - (return), but only when we're in a %hook.
			while($inclass && $line =~ /^\s*([+-])\s*\(\s*(.*?)\s*\)/g) {
				next if fallsBetween($-[0], @quotes);

				# Gasp! We've been moved to a different group!
				if($class->group != $curGroup) {
					my $classname = $class->name;
					$class = $curGroup->addClassNamed($classname);
				}

				my $scope = $1;
				my $return = $2;
				my $selnametext = $';

				my $currentMethod = Method->new();

				$currentMethod->class($class);
				if($scope eq "+") {
					$class->hasmetahooks(1);
				} else {
					$classes{$class->name}++;
					$class->hasinstancehooks(1);
				}

				$currentMethod->scope($scope);
				$currentMethod->return($return);

				if($isNewMethod) {
					$currentMethod->setNew(1);
					$currentMethod->type($isNewMethod);
					$isNewMethod = undef;
				}

				my @selparts = ();

				# word, then an optional: ": (argtype)argname"
				while($selnametext =~ /^\s*([\$\w]*)(:\s*\((.+?)\)\s*([\$\w]+?)\b)?/) {
					last if !$1 && !$2; # Exit the loop if both Keywords and Args are missing: e.g. false positive.

					$keyword = $1; # Add any keyword.
					push(@selparts, $keyword);

					$selnametext = $';

					last if !$2;  # Exit the loop if there are no args (single keyword.)
					$currentMethod->addArgument($3, $4);
				}

				$currentMethod->selectorParts(@selparts);
				$currentMethod->groupIdentifier(sanitize($curGroup->name));
				$class->addMethod($currentMethod);
				$lastMethod = $currentMethod;

				$replacement = $currentMethod->buildMethodSignature;
				$replacement .= $selnametext if $selnametext ne "";
				$line = $replacement;

				redo SCANLOOP;
			}

			while($line =~ /%orig(inal)?(%?)(?=\W?)/g) {
				next if fallsBetween($-[0], @quotes);

				nestingMustContain($lineno, $&, \@nestingstack, "hook", "subclass");
				fileWarning($lineno, "$& in a new method will be non-operative.") if $lastMethod->isNew;

				my $hasparens = 0;
				my $remaining = $';
				$replacement = "";
				if($remaining) {
					# If we encounter a ) that puts us back at zero, we found a (
					# and have reached its closing ).
					my $parenmatch = $remaining;
					my $pdepth = 0;
					my @pquotes = quotes($parenmatch);
					while($parenmatch =~ /[;()]/g) {
						next if fallsBetween($-[0], @pquotes);

						# If we hit a ; at depth 0 without having a ( ) pair, bail.
						last if $& eq ";" && $pdepth == 0;

						if($& eq "(") { $pdepth++; }
						elsif($& eq ")") {
							$pdepth--;
							if($pdepth == 0) { $hasparens = $+[0]; last; }
						}
					}
				}
				if($hasparens > 0) {
					$parenstring = substr($remaining, 1, $hasparens-2);
					$remaining = substr($remaining, $hasparens);
					$replacement .= $lastMethod->buildOriginalCall($parenstring);
				} else {
					$replacement .= $lastMethod->buildOriginalCall;
				}
				$replacement .= $remaining;
				$line = $`.$replacement;

				redo SCANLOOP;
			}
			
			while($line =~ /%log(%?)(?=\W?)/g) {
				next if fallsBetween($-[0], @quotes);

				nestingMustContain($lineno, $&, \@nestingstack, "hook", "subclass");
				$replacement = $lastMethod->buildLogCall;
				$line = $`.$replacement.$';

				redo SCANLOOP;
			}
			
			while($line =~ /%c(onstruc)?tor(%?)(?=\W?)/g) {
				next if fallsBetween($-[0], @quotes);

				nestingMustNotContain($lineno, $&, \@nestingstack, "hook", "subclass");
				$ctorline = $lineno if $ctorline == -1;
				$line = $`.$';

				redo SCANLOOP;
			}

			while($line =~ /%init(\((.*?)\))?(%?);?(?=\W?)/g) {
				next if fallsBetween($-[0], @quotes);

				$before = $`;
				$after = $';

				my $groupname = "_ungrouped";
				my @args = split(/,/, $2);

				my $tempgroupname = undef;
				$tempgroupname = $args[0] if $args[0] && $args[0] !~ /=/;
				if(defined($tempgroupname)) {
					$groupname = $tempgroupname;
					shift(@args);
				}

				my $group = getGroup($groupname);

				foreach $arg (@args) {
					$arg =~ s/\s+//;
					if($arg !~ /=/) {
						fileWarning($lineno, "unknown argument to %init: $arg");
						next;
					}

					my @parts = split(/\s*=\s*/, $arg);
					if(!defined($parts[0]) || !defined($parts[1])) {
						fileWarning($lineno, "invalid class=expr in %init");
						next;
					}

					my $classname = $parts[0];
					my $expr = $parts[1];
					my $scope = "-";
					if($classname =~ /^([+-])/) {
						$scope = $1;
						$classname = $';
					}

					my $class = $group->getClassNamed($classname);
					if(!defined($class)) {
						fileWarning($lineno, "tried to set expression for unknown class $classname in group $groupname");
						next;
					}

					$class->expression($expr) if $scope eq "-";
					$class->metaexpression($expr) if $scope eq "+";
				}

				$line = $before.generateInitLines($group).$after;
				$ctorline = -2; # "Do not generate a constructor."
				$lastInitLine = $lineno;

				redo SCANLOOP;
			}
			
			# %end (Make it the last thing we check for so we don't terminate something pre-emptively.
			while($line =~ /%end(%?)/g) {
				next if fallsBetween($-[0], @quotes);

				my $closing = nestPop(\@nestingstack);
				fileError($lineno, "dangling %end") if !$closing;
				if($closing eq "group") {
					$curGroup = getGroup("_ungrouped");
				} 
				if($closing eq "hook" || $closing eq "subclass") {
					$inclass = 0;
				}
				$line = $`.$';

				redo SCANLOOP;
			}

			# If we made it here, there are no more non-quoted commands on this line! Yay! Break free!
			last;
		}
	}
	$lineno++;
	push(@outputlines, $line);
}

while(scalar(@nestingstack) > 0) {
	my $closing = pop(@nestingstack);
	my @parts = split(/:/, $closing);
	fileWarning(-1, "missing %end (%".$parts[0]." opened on line ".$parts[1]." extends to EOF)");
}

push(@groups, $staticClassGroup);

if($firsthookline != -1) {
	my $offset = 0;
	if(!$hassubstrateh) {
		splice(@outputlines, $firsthookline - 1, 0, "#include <substrate.h>");
		$offset++;
	}
	splice(@outputlines, $firsthookline - 1 + $offset, 0, generateClassList());
	$offset++;
	splice(@outputlines, $firsthookline - 1 + $offset, 0, $staticClassGroup->declarations);
	$offset++;
	splice(@outputlines, $firsthookline - 1 + $offset, 0, "#line $firsthookline \"$filename\"");
	$offset++;
	if($ctorline == -2) {
		# If the static class list hasn't been initialized, glue it under the last %init line.
		if(!$staticClassGroup->initialized) {
			splice(@outputlines, $lastInitLine + $offset, 0, $staticClassGroup->initializers);
			$offset++;
			splice(@outputlines, $lastInitLine + $offset, 0, "#line ".($lastInitLine+1)." \"$filename\"");
			$offset++;
		}
	} elsif($ctorline != -1) {
		$outputlines[$ctorline + $offset - 1] = generateConstructor();
	} else {
		push(@outputlines, generateConstructor());
	}

}

my @unInitGroups = ();
foreach(@groups) {
	push(@unInitGroups, $_->name) if !$_->initialized && $_->explicit;
}
my $numUnGroups = @unInitGroups;
fileError(-1, "non-initialized hook group".($numUnGroups == 1 ? "" : "s").": ".join(", ", @unInitGroups)) if $numUnGroups > 0;

splice(@outputlines, 0, 0, "#line 1 \"$filename\"");
foreach $oline (@outputlines) {
	print $oline."\n" if defined($oline);
}

sub generateConstructor {
	my $return = "";
	my $explicitGroups = 0;
	foreach(@groups) {
		$explicitGroups++ if $_->explicit;
	}
	fileError($ctorline, "Cannot generate an autoconstructor with multiple %groups. Please explicitly create a constructor.") if $explicitGroups > 0;
	$return .= "static __attribute__((constructor)) void _logosLocalInit() { ";
	$return .= "NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init]; ";
	foreach(@groups) {
		next if $_->explicit;
		$return .= generateInitLines($_)." ";
	}
	$return .= "[pool drain];";
	$return .= " }";
	return $return;
}

sub generateInitLines {
	my $group = shift;
	$group = getGroup("_ungrouped") if !$group;

	if(!$group) {
		fileError($lineno, "%init for an undefined %group $groupname");
		return;
	}

	if($group->initialized) {
		fileError($lineno, "re-%init of %group $groupname");
		return;
	}

	my $return = $group->initializers;
	return $return;
}

sub generateClassList {
	my $return = "";
	map $return .= "\@class $_; ", sort keys %classes;
	return $return;
}

sub quotes {
	my ($line) = @_;
	my @quotes = ();
	while($line =~ /(?<!\\)\"/g) {
		push(@quotes, $-[0]);
	}
	return @quotes;
}

sub fallsBetween {
	my $idx = shift;
	while(@_ > 0) {
		my $start = shift;
		my $end = shift;
		return 1 if ($start < $idx && (!defined($end) || $end > $idx))
	}
	return 0;
}

sub fileWarning {
	my $curline = shift;
	my $reason = shift;
	print STDERR "$filename:".($curline > -1 ? "$curline:" : "")." warning: $reason\n";
}

sub fileError {
	my $curline = shift;
	my $reason = shift;
	die "$filename:".($curline > -1 ? "$curline:" : "")." error: $reason\n";
}

sub nestingError {
	my $curline = shift;
	my $thisblock = shift;
	my $reason = shift;
	my @parts = split(/:/, $reason);
	fileError $curline, "$thisblock inside a %".$parts[0].", opened on line ".$parts[1];
}

sub nestingMustContain {
	my $lineno = shift;
	my $trying = shift;
	my $stackref = shift;
	return if nestingContains($stackref, @_);
	fileError($lineno, "$trying found outside of ".join(" or ", @_));
}

sub nestingMustNotContain {
	my $lineno = shift;
	my $trying = shift;
	my $stackref = shift;
	nestingError($lineno, $trying, $_) if nestingContains($stackref, @_);
}

sub nestingContains {
	my $stackref = shift;
	my @stack = @$stackref;
	my @search = @_;
	my @parts = ();
	foreach $nest (@stack) {
		@parts = split(/:/, $nest);
		foreach $find (@search) {
			if($find eq $parts[0]) {
				$_ = $nest;
				return $_;
			}
		}
	}
	$_ = undef;
	return undef;
}

sub nestPush {
	my $type = shift;
	my $line = shift;
	my $ref_stack = shift;
	push(@{$ref_stack}, $type.":".$line);
}

sub nestPop {
	my $ref_stack = shift;
	my $outgoing = pop(@{$ref_stack});
	return undef if !$outgoing;
	my @parts = split(/:/, $outgoing);
	return $parts[0];
}

sub sanitize {
	my $input = shift;
	my $output = $input;
	$output =~ s/[^\w]//g;
	return $output;
}

sub getGroup {
	my $name = shift;
	foreach(@groups) {
		return $_ if $_->name eq $name;
	}
	return undef;
}
