# tinytrader-deploy.watchFresh: the stamps this Mac's monitor checks for age
# (tinytrader's watch, WATCH_FRESH: NAME:MAX_AGE_SECONDS:PATH each), from
# every module that leaves one (the backup's, the network check's).
# modules/watch-darwin.nix hands them to the monitor. Imported by each of
# those modules (the module system imports a file once).
{ lib, ... }:
{
  options.tinytrader-deploy.watchFresh = lib.mkOption {
    type = lib.types.listOf (lib.types.strMatching "[^: ]+:[0-9]+:[^ ]+");
    default = [ ];
    example = [ "backup:108000:/var/lib/tinytrader-backup/last-backup" ];
    description = "Files that must have changed recently, NAME:MAX_AGE_SECONDS:PATH each, for the monitor.";
  };
}
