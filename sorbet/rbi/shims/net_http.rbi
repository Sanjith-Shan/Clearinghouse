# typed: strict

# Net::HTTP accessors that exist in net-http 0.4 (Ruby 3.3) but are missing from
# Sorbet's bundled stdlib RBI. SafeHttp depends on ipaddr= to connect to the address
# it checked while the hostname still drives SNI and certificate verification.
class Net::HTTP
  sig { params(addr: String).void }
  def ipaddr=(addr); end

  sig { params(sec: T.nilable(Numeric)).void }
  def write_timeout=(sec); end

  sig { params(value: T::Boolean).void }
  def verify_hostname=(value); end
end
