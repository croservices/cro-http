#!/bin/sh

# Generate self signed root CA cert
openssl req -days 365 -config my.conf -nodes -x509 -newkey rsa:4096 -keyout ca.key -out ca-crt.pem -subj "/C=CZ/ST=Central Bohemia/L=Prague/O=CA/OU=IT/CN=localhost/emailAddress=foo@example.net"

# Generate server cert to be signed
openssl req -nodes -newkey rsa:4096 -keyout server-key.pem -out server.csr -subj "/C=CZ/ST=Central Bohemia/L=Prague/O=foo/OU=IT/CN=localhost/emailAddress=foo@example.net"

# Sign the server cert
openssl x509 -req -days 365 -in server.csr -CA ca-crt.pem -CAkey ca.key -CAcreateserial -out server-crt.pem -extensions req_ext -extfile my.conf

# Clean up extra files
rm ca-crt.srl ca.key server.csr

# Verify certs validate correctly
echo "-----"
echo "Verifying certs"
openssl verify -CAfile ca-crt.pem ca-crt.pem
openssl verify -CAfile ca-crt.pem server-crt.pem
