use Crypt::Random::Extra;

our sub generate-session-id() is export {
    my constant @CHARS = flat 'A'..'Z', 'a'..'z', '0'..'9';
    crypt_random_sample(@CHARS, 64).join;
}
