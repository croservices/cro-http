#!/usr/bin/env sh

# Go to the scripts dir ======================================================

# https://stackoverflow.com/a/29835459
rreadlink() (
  target=$1 fname= targetDir= CDPATH=
  { \unalias command; \unset -f command; } >/dev/null 2>&1
  [ -n "$ZSH_VERSION" ] && options[POSIX_BUILTINS]=on
  while :; do
      [ -L "$target" ] || [ -e "$target" ] || { command printf '%s\n' "ERROR: '$target' does not exist." >&2; return 1; }
      command cd "$(command dirname -- "$target")"
      fname=$(command basename -- "$target")
      [ "$fname" = '/' ] && fname=''
      if [ -L "$fname" ]; then
        target=$(command ls -l "$fname")
        target=${target#* -> }
        continue
      fi
      break
  done
  targetDir=$(command pwd -P)
  if [ "$fname" = '.' ]; then
    command printf '%s\n' "${targetDir%/}"
  elif  [ "$fname" = '..' ]; then
    command printf '%s\n' "$(command dirname -- "${targetDir}")"
  else
    command printf '%s\n' "${targetDir%/}/$fname"
  fi
)

DIR=$(dirname -- "$(rreadlink "$0")")
cd $DIR


# Actual logic ===============================================================

# Remove old certs
rm *.pem

# CA
openssl req -new -nodes -days 365 -x509 -subj '/CN=localhost/C=DE/ST=BW/L=Stuttgart/O=CroCA/emailAddress=foo@example.net' -keyout ca-key.pem -out ca-crt.pem

# Server
openssl req -new -nodes -newkey rsa:4096 -subj '/CN=localhost/C=DE/ST=BW/L=Stuttgart/O=CroCompany/emailAddress=foo@example.net' -addext "subjectAltName = DNS:localhost" -keyout server-key.pem -out server-crt.csr

cat <<EOT >> extfile
[ v3_req ]
keyUsage = digitalSignature, keyEncipherment
subjectAltName = DNS:localhost
EOT
openssl x509 -req -days 365 -sha256 -CAcreateserial -extensions v3_req -extfile extfile -in server-crt.csr -CA ca-crt.pem -CAkey ca-key.pem -out server-crt.pem

# Remove temporary and unneeded files
rm ca-crt.srl ca-key.pem server-crt.csr extfile


# Other stuff ================================================================

# Inspect a certificate file:
#openssl x509 -in xt/certs-and-keys/server-crt.pem -text

# Inspect a key file:
#openssl rsa -in xt/certs-and-keys/server-key.pem -text

