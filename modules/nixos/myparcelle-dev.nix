# Only the public edge belongs to the machine. The development checkout owns
# its application and isolated identity service; neither upstream is exposed
# beyond loopback, and an absent checkout answers 502 rather than a fallback.
_: {
  services.caddy.virtualHosts = {
    "myparcelle.tyrode.dev".extraConfig = ''
      encode zstd gzip
      header Cache-Control "no-store"
      @storybook path /storybook /storybook/*
      respond @storybook 404
      reverse_proxy 127.0.0.1:4173
    '';
    "auth.myparcelle.tyrode.dev".extraConfig = ''
      @public path /realms/myparcelle/* /resources/* /robots.txt
      handle @public {
        reverse_proxy 127.0.0.1:8082
      }
      respond 404
    '';
  };
}
