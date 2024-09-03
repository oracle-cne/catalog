%global debug_package %{nil}
%global _buildhost          build-ol%{?oraclelinux}-%{?_arch}.oracle.com

Name:		ocne-catalog
Version:	2.0.0
Release:	1%{?dist}
Summary:	An on-disk Helm chart repository

Group:		Development/Tools
License:	UPL 1.0
Source0:	%{name}-%{version}.tar.bz2

BuildRequires:	helm
BuildRequires:	make
BuildRequires:	findutils

%description
An on-disk Helm chart repository

%prep
%setup -q


%build
make


%install
install -m 755 -d %{buildroot}/opt/charts
cp -r repo/* %{buildroot}/opt/charts
install -m 755 -d %{buildroot}/opt/icons
cp -ap olm/icons/* %{buildroot}/opt/icons

%files
%license LICENSE.txt
/opt/charts
/opt/icons

%changelog
* Fri Aug 30 2024 Daniel Krasinski <daniel.krasinski@oracle.com> 2.0.0-1
- Applications for Oracle Cloud Native Environment
