{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    bandit = buildMix rec {
      name = "bandit";
      version = "1.10.3";

      src = fetchHex {
        pkg = "bandit";
        version = "${version}";
        sha256 = "99a52d909c48db65ca598e1962797659e3c0f1d06e825a50c3d75b74a5e2db18";
      };

      beamDeps = [ hpax plug telemetry thousand_island websock ];
    };

    db_connection = buildMix rec {
      name = "db_connection";
      version = "2.9.0";

      src = fetchHex {
        pkg = "db_connection";
        version = "${version}";
        sha256 = "17d502eacaf61829db98facf6f20808ed33da6ccf495354a41e64fe42f9c509c";
      };

      beamDeps = [ telemetry ];
    };

    decimal = buildMix rec {
      name = "decimal";
      version = "2.3.0";

      src = fetchHex {
        pkg = "decimal";
        version = "${version}";
        sha256 = "a4d66355cb29cb47c3cf30e71329e58361cfcb37c34235ef3bf1d7bf3773aeac";
      };

      beamDeps = [];
    };

    dialyxir = buildMix rec {
      name = "dialyxir";
      version = "1.4.7";

      src = fetchHex {
        pkg = "dialyxir";
        version = "${version}";
        sha256 = "b34527202e6eb8cee198efec110996c25c5898f43a4094df157f8d28f27d9efe";
      };

      beamDeps = [ erlex ];
    };

    ecto = buildMix rec {
      name = "ecto";
      version = "3.13.5";

      src = fetchHex {
        pkg = "ecto";
        version = "${version}";
        sha256 = "df9efebf70cf94142739ba357499661ef5dbb559ef902b68ea1f3c1fabce36de";
      };

      beamDeps = [ decimal jason telemetry ];
    };

    ecto_sql = buildMix rec {
      name = "ecto_sql";
      version = "3.13.5";

      src = fetchHex {
        pkg = "ecto_sql";
        version = "${version}";
        sha256 = "aa36751f4e6a2b56ae79efb0e088042e010ff4935fc8684e74c23b1f49e25fdc";
      };

      beamDeps = [ db_connection ecto postgrex telemetry ];
    };

    erlex = buildMix rec {
      name = "erlex";
      version = "0.2.8";

      src = fetchHex {
        pkg = "erlex";
        version = "${version}";
        sha256 = "9d66ff9fedf69e49dc3fd12831e12a8a37b76f8651dd21cd45fcf5561a8a7590";
      };

      beamDeps = [];
    };

    file_system = buildMix rec {
      name = "file_system";
      version = "1.1.1";

      src = fetchHex {
        pkg = "file_system";
        version = "${version}";
        sha256 = "7a15ff97dfe526aeefb090a7a9d3d03aa907e100e262a0f8f7746b78f8f87a5d";
      };

      beamDeps = [];
    };

    finch = buildMix rec {
      name = "finch";
      version = "0.21.0";

      src = fetchHex {
        pkg = "finch";
        version = "${version}";
        sha256 = "87dc6e169794cb2570f75841a19da99cfde834249568f2a5b121b809588a4377";
      };

      beamDeps = [ mime mint nimble_options nimble_pool telemetry ];
    };

    hpax = buildMix rec {
      name = "hpax";
      version = "1.0.3";

      src = fetchHex {
        pkg = "hpax";
        version = "${version}";
        sha256 = "8eab6e1cfa8d5918c2ce4ba43588e894af35dbd8e91e6e55c817bca5847df34a";
      };

      beamDeps = [];
    };

    jason = buildMix rec {
      name = "jason";
      version = "1.4.4";

      src = fetchHex {
        pkg = "jason";
        version = "${version}";
        sha256 = "c5eb0cab91f094599f94d55bc63409236a8ec69a21a67814529e8d5f6cc90b3b";
      };

      beamDeps = [ decimal ];
    };

    mime = buildMix rec {
      name = "mime";
      version = "2.0.7";

      src = fetchHex {
        pkg = "mime";
        version = "${version}";
        sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
      };

      beamDeps = [];
    };

    mint = buildMix rec {
      name = "mint";
      version = "1.7.1";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "fceba0a4d0f24301ddee3024ae116df1c3f4bb7a563a731f45fdfeb9d39a231b";
      };

      beamDeps = [ hpax ];
    };

    mox = buildMix rec {
      name = "mox";
      version = "1.2.0";

      src = fetchHex {
        pkg = "mox";
        version = "${version}";
        sha256 = "c7b92b3cc69ee24a7eeeaf944cd7be22013c52fcb580c1f33f50845ec821089a";
      };

      beamDeps = [ nimble_ownership ];
    };

    nimble_options = buildMix rec {
      name = "nimble_options";
      version = "1.1.1";

      src = fetchHex {
        pkg = "nimble_options";
        version = "${version}";
        sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
      };

      beamDeps = [];
    };

    nimble_ownership = buildMix rec {
      name = "nimble_ownership";
      version = "1.0.2";

      src = fetchHex {
        pkg = "nimble_ownership";
        version = "${version}";
        sha256 = "098af64e1f6f8609c6672127cfe9e9590a5d3fcdd82bc17a377b8692fd81a879";
      };

      beamDeps = [];
    };

    nimble_pool = buildMix rec {
      name = "nimble_pool";
      version = "1.1.0";

      src = fetchHex {
        pkg = "nimble_pool";
        version = "${version}";
        sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
      };

      beamDeps = [];
    };

    plug = buildMix rec {
      name = "plug";
      version = "1.19.1";

      src = fetchHex {
        pkg = "plug";
        version = "${version}";
        sha256 = "560a0017a8f6d5d30146916862aaf9300b7280063651dd7e532b8be168511e62";
      };

      beamDeps = [ mime plug_crypto telemetry ];
    };

    plug_crypto = buildMix rec {
      name = "plug_crypto";
      version = "2.1.1";

      src = fetchHex {
        pkg = "plug_crypto";
        version = "${version}";
        sha256 = "6470bce6ffe41c8bd497612ffde1a7e4af67f36a15eea5f921af71cf3e11247c";
      };

      beamDeps = [];
    };

    postgrex = buildMix rec {
      name = "postgrex";
      version = "0.22.0";

      src = fetchHex {
        pkg = "postgrex";
        version = "${version}";
        sha256 = "a68c4261e299597909e03e6f8ff5a13876f5caadaddd0d23af0d0a61afcc5d84";
      };

      beamDeps = [ db_connection decimal jason ];
    };

    req = buildMix rec {
      name = "req";
      version = "0.5.17";

      src = fetchHex {
        pkg = "req";
        version = "${version}";
        sha256 = "0b8bc6ffdfebbc07968e59d3ff96d52f2202d0536f10fef4dc11dc02a2a43e39";
      };

      beamDeps = [ finch jason mime plug ];
    };

    telemetry = buildRebar3 rec {
      name = "telemetry";
      version = "1.3.0";

      src = fetchHex {
        pkg = "telemetry";
        version = "${version}";
        sha256 = "7015fc8919dbe63764f4b4b87a95b7c0996bd539e0d499be6ec9d7f3875b79e6";
      };

      beamDeps = [];
    };

    thousand_island = buildMix rec {
      name = "thousand_island";
      version = "1.4.3";

      src = fetchHex {
        pkg = "thousand_island";
        version = "${version}";
        sha256 = "6e4ce09b0fd761a58594d02814d40f77daff460c48a7354a15ab353bb998ea0b";
      };

      beamDeps = [ telemetry ];
    };

    typed_ecto_schema = buildMix rec {
      name = "typed_ecto_schema";
      version = "0.4.3";

      src = fetchHex {
        pkg = "typed_ecto_schema";
        version = "${version}";
        sha256 = "dcbd9b35b9fda5fa9258e0ae629a99cf4473bd7adfb85785d3f71dfe7a9b2bc0";
      };

      beamDeps = [ ecto ];
    };

    typed_struct = buildMix rec {
      name = "typed_struct";
      version = "0.3.0";

      src = fetchHex {
        pkg = "typed_struct";
        version = "${version}";
        sha256 = "c50bd5c3a61fe4e198a8504f939be3d3c85903b382bde4865579bc23111d1b6d";
      };

      beamDeps = [];
    };

    yamerl = buildRebar3 rec {
      name = "yamerl";
      version = "0.10.0";

      src = fetchHex {
        pkg = "yamerl";
        version = "${version}";
        sha256 = "346adb2963f1051dc837a2364e4acf6eb7d80097c0f53cbdc3046ec8ec4b4e6e";
      };

      beamDeps = [];
    };

    yaml_elixir = buildMix rec {
      name = "yaml_elixir";
      version = "2.12.1";

      src = fetchHex {
        pkg = "yaml_elixir";
        version = "${version}";
        sha256 = "d9ac16563c737d55f9bfeed7627489156b91268a3a21cd55c54eb2e335207fed";
      };

      beamDeps = [ yamerl ];
    };

    websock = buildMix rec {
      name = "websock";
      version = "0.5.3";

      src = fetchHex {
        pkg = "websock";
        version = "${version}";
        sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
      };

      beamDeps = [];
    };
  };
in self

