class Cro::HTTP2::ConnectionState {
    has Supplier $.settings = Supplier.new;
    has Supplier $.ping = Supplier.new;
    has Supplier $.window-size = Supplier.new;
}
