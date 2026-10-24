{ profilesLib, inBoxNames }:
profilesLib.mkProfileBundle {
  name = "tui-spec";
  inherit inBoxNames;
  plugins = [
    ("file:" + toString ./../plugins/tui-core)
  ];
  specsHash = "sha256-y0VNIfYbBigla8KKVSmYYEShNI2A8qZtAkDzbq1ZiuQ=";
}
