%global debug_package %{nil}
%global _buildhost          build-ol%{?oraclelinux}-%{?_arch}.oracle.com
%global registry container-registry.oracle.com/olcne
%global _name ocne-catalog
%global rpm_name %{_name}-%{version}-%{release}.%{_build_arch}
%global docker_tag %{registry}/%{_name}:v%{version}

Name:		%{_name}-container-image
Version:	2.0.0
Release:	6%{?dist}
Summary:	An on-disk Helm chart repository

Group:		Development/Tools
License:	UPL 1.0
Source0:	%{name}-%{version}.tar.bz2

%description
An on-disk Helm chart repository

%prep
%setup -q

%build
yum clean all
yumdownloader --destdir=${PWD}/rpms %{rpm_name}

docker build --pull --build-arg https_proxy=${https_proxy} \
	-t %{docker_tag} -f ./olm/builds/Dockerfile .
docker save -o %{_name}.tar %{docker_tag}

%install
%__install -D -m 644 %{_name}.tar %{buildroot}/usr/local/share/olcne/%{_name}.tar

%files
/usr/local/share/olcne/%{_name}.tar

%clean

%changelog
* Wed Oct 23 2024 Michael Gianatassio <michael.gianatassio@oracle.com> - 2.0.0-6
- Add Fluentd
- Add Istio 1.19
- Remove requirement for Istio from Grafana

* Thu Oct 10 2024 Daniel Krasinski <daniel.krasinski@oracle.com> - 2.0.0-5
- Add several applications

* Thu Sep 12 2024 Raaghav Wadhawan <raaghav.w.wadhawan@oracle.com> 2.0.0-4
- Update Dex and cert-manager-webhook-oci icons.

* Tue Sep 10 2024 Zaid Abdulrehman <zaid.a.abdulrehman@oracle.com> 2.0.0-3
- Change UI and catalog to use fully qualified images

* Fri Sep 06 2024 Daniel Krasinski <daniel.krasinski@oracle.com> 2.0.0-2
- Correct a few applications that did not properly annotate their container images

* Fri Aug 30 2024 Daniel Krasinski <daniel.krasinski@oracle.com> 2.0.0-1
- Applications for Oracle Cloud Native Environment
