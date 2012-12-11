package Logos::Generator::internal::Subclass;
use strict;
use parent qw(Logos::Generator::internal::Class);

# declarations is inherited from Class.

sub _initExpression {
	my $self = shift;
	my $class = shift;
	return "objc_allocateClassPair(objc_getClass(\"".$class->superclass."\"), \"".$class->name."\", 0)";
}

sub initializers {
	my $self = shift;
	my $class = shift;
	my $return = "";
	$return .= "{ ";
	$return .= $self->SUPER::initializers($class)." ";
	# <ivars>
	foreach(@{$class->ivars}) {
		$return .= Logos::Generator::for($_)->initializers;
	}
	# </ivars>
	foreach(keys %{$class->protocols}) {
		$return .= "class_addProtocol(".$self->variable($class).", objc_getProtocol(\"$_\")); ";
	}
	$return .= "objc_registerClassPair(".$self->variable($class)."); ";
	$return .= "}";
	return $return;
}

1;
