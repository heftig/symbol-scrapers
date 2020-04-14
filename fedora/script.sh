#!/bin/sh
unalias -a

if [ -z "${DUMP_SYMS}" ]; then
  printf "You must set the \`DUMP_SYMS\` enviornment variable before running the script\n"
  exit 1
fi

if [ -z "${SYMBOLS_API_TOKEN}" ]; then
  printf "You must set the \`SYMBOLS_API_TOKEN\` enviornment variable before running the script\n"
  exit 1
fi

if [ -z "${CRASHSTATS_API_TOKEN}" ]; then
  printf "You must set the \`CRASHSTATS_API_TOKEN\` enviornment variable before running the script\n"
  exit 1
fi

URL="https://fedora.mirror.wearetriple.com/linux"
RELEASES="30 31 32 test/32_Beta"

get_package_urls() {
  local package_name=${1}
  local dbg_package_name="${package_name}-debuginfo"
  local url=${3:-$URL}

  grep -h -o "$url.*/\(${package_name}-[0-9].*.x86_64.rpm\|${dbg_package_name}-[0-9].*.x86_64.rpm\)\"" index.html* | cut -d'"' -f1
}

get_package_indexes() {
  local pkg_path=${2}
  local url=${3:-$URL}

  local everything_dir=""
  local packages_dir=""
  local tree_dir=""

  if [ -z "${3}" ]; then
    everything_dir="Everything"
    packages_dir="Packages"
    tree_dir="tree"
  fi

  for release in ${RELEASES}; do
    printf "${url}/releases/${release}/Everything/x86_64/os/Packages/${pkg_path}/\n"
    printf "${url}/releases/${release}/Everything/x86_64/debug/${tree_dir}/${packages_dir}/${pkg_path}/\n"
    printf "${url}/updates/${release}/${everything_dir}/x86_64/${packages_dir}/${pkg_path}/\n"
    printf "${url}/updates/${release}/${everything_dir}/x86_64/debug/${packages_dir}/${pkg_path}/\n"
  done

  # 32 testing, should be moved above
  printf "${url}/updates/testing/32/${everything_dir}/x86_64/${packages_dir}/${pkg_path}/\n"
  printf "${url}/updates/testing/32/${everything_dir}/x86_64/debug/${packages_dir}/${pkg_path}/\n"

  # 32 beta
  printf "${url}/development/32/${everything_dir}/x86_64/os/Packages/${pkg_path}/\n"
  printf "${url}/development/32/${everything_dir}/x86_64/debug/${tree_dir}/${packages_dir}/${pkg_path}/\n"

  # Rawhide
  printf "${url}/development/rawhide/${everything_dir}/x86_64/os/Packages/${pkg_path}/\n"
  printf "${url}/development/rawhide/${everything_dir}/x86_64/debug/${tree_dir}/${packages_dir}/${pkg_path}/\n"
}

fetch_packages() {
  echo "${1}" | while read line; do
    [ -z "${line}" ] && continue
    get_package_indexes ${line}
  done | sort -u > indexes.txt

  wget -o wget.log --compression=auto -k -i indexes.txt

  echo "${1}" | while read line; do
    [ -z "${line}" ] && continue
    get_package_urls ${line} >> packages.txt
  done

  rm -f index.html*

  wget -o wget.log -P downloads -c -i packages.txt

  rev packages.txt | cut -d'/' -f1 | rev > package_names.txt
}

unpack_package() {
  package_filename="${1##downloads/}"
  package_name="${package_filename%%.rpm}"

  if [[ ${package_filename} =~ -debuginfo- ]]; then
    mkdir -p "debug/${package_name}"
    rpm2cpio "${1}" | cpio --quiet -i -d -D "debug/${package_name}"
  else
    mkdir -p "tmp/${package_name}"
    rpm2cpio "${1}" | cpio --quiet -i -d -D "tmp/${package_name}"
  fi
}

get_build_id() {
  echo "${1}" | cut -d'=' -f2 | cut -d',' -f1
}

merge_debug_info() {
  buildid=${2}
  prefix=$(echo "${buildid}" | cut -b1-2)
  suffix=$(echo "${buildid}" | cut -b3-)
  debuginfo=$(find debug -path "*/${prefix}/${suffix}.debug" | head -n1)
  file_output=$(file -L "${debuginfo}")
  tbuildid=$(get_build_id "${file_output}")
  if [ "$buildid" == "$tbuildid" ]; then
    tmpfile=$(mktemp tmp.XXXXXXXX -u)
    objcopy --decompress-debug-sections --no-adjust-warnings "${debuginfo}" "${tmpfile}"
    eu-unstrip "${1}" "${tmpfile}"
    printf "Merging ${tmpfile} to ${1}\n"
    /bin/cp -f "${tmpfile}" "${1}"
    rm -f "${tmpfile}"
  else
    printf "Could not find debuginfo for ${1}\n" >> error.log
  fi
}

function get_soname {
  local path="${1}"
  local soname=$(objdump -p "${path}" | grep "^  SONAME *" | cut -b24-)
  if [ -n "${soname}" ]; then
    printf "${soname}"
  else
    local filename=$(basename "${path}")
    printf "${filename}"
  fi
}

purge_old_packages() {
  find downloads | while read line; do
    name=$(echo "${line}" | cut -d'/' -f2)

    if ! grep -q ${name} package_names.txt; then
      rm -vf "downloads/${name}"
    fi
  done
}

rm -rf symbols debug tmp symbols*.zip error.log packages.txt package_names.txt
mkdir -p downloads
mkdir -p symbols
mkdir -p tmp
mkdir -p debug

packages="
alsa-lib a
at-spi2-atk a
at-spi2-core a
atk a
cairo c
dbus-glib d
dbus-libs d
dconf d
ffmpeg-libs f http://mirror.nl.leaseweb.net/rpmfusion/free/fedora
fontconfig f
freetype f
fribidi f
gdk-pixbuf2 g
glib2 g
glibc g
glib-networking g
gnome-vfs2 g
gtk2 g
gtk3 g
libdrm l
libepoxy l
libevent l
libffi l
libICE l
libicu l
libpng12 l
libpng l
libproxy l
libSM l
libstdc++ l
libthai l
libvpx l
libwayland-client l
libx11 l
libxcb l
libXext l
libxml2 l
mesa-dri-drivers m
mesa-libEGL m
mesa-libGL m
nspr n
opus o
pango p
pcre p
pcsc-lite-libs p
pixman p
pulseaudio-libs p
speech-dispatcher s
systemd-libs s
x264-libs x http://mirror.nl.leaseweb.net/rpmfusion/free/fedora
x265-libs x http://mirror.nl.leaseweb.net/rpmfusion/free/fedora
xvidcore x http://mirror.nl.leaseweb.net/rpmfusion/free/fedora
zlib z
"

fetch_packages "${packages}"

find downloads -name "*.rpm" -type f | while read path; do
  filename="${path##downloads/}"
  if ! grep -q -F "${filename}" SHA256SUMS; then
    unpack_package "${path}"
    echo "$filename" >> SHA256SUMS
  fi
done

find tmp -type f | while read path; do
  file_output=$(file "${path}")
  if echo "${file_output}" | grep -q "ELF \(32\|64\)-bit LSB \(shared object\|pie executable\)" ; then
    soname=$(get_soname "${path}")
    buildid=$(get_build_id "${file_output}")
    merge_debug_info "${path}" "${buildid}"
    tmpfile=$(mktemp)
    printf "Writing symbol file for ${path} ... "
    ${DUMP_SYMS} "${path}" > "${tmpfile}"
    printf "done\n"
    debugid=$(head -n 1 "${tmpfile}" | cut -d' ' -f4)
    mkdir -p "symbols/${soname}/${debugid}"
    mv "${tmpfile}" "symbols/${soname}/${debugid}/${soname}.sym"
    file_size=$(stat -c "%s" "${path}")
    # Copy the object file only if it's not larger than roughly 2GiB
    if [ $file_size -lt 2100000000 ]; then
      /bin/cp -f "${path}" "symbols/${soname}/${debugid}/${soname}"
    fi
  fi
done

cd symbols
zip_count=1
total_size=0
find . -mindepth 2 -type d | while read path; do
  size=$(du -s -b "${path}" | cut -f1)
  zip -r "../symbols${zip_count}.zip" "${path##./}"
  total_size=$((total_size + size))
  if [[ ${total_size} -gt 500000000 ]]; then
    zip_count=$((zip_count + 1))
    total_size=0
  fi
done
cd ..

find . -name "*.zip" | while read myfile; do
  printf "Uploading ${myfile}\n"
  while : ; do
    res=$(curl -H "auth-token: ${SYMBOLS_API_TOKEN}" --form ${myfile}=@${myfile} https://symbols.mozilla.org/upload/)
    if [ -n "${res}" ]; then
      echo "${res}"
      break
    fi
  done
done

find symbols -mindepth 2 -maxdepth 2 -type d | while read module; do
  module_name=${module##symbols/}
  crashes=$(supersearch --num=all --modules_in_stack=${module_name//-})
  if [ -n "${crashes}" ]; then
   echo "${crashes}" | reprocess
  fi
done

purge_old_packages
