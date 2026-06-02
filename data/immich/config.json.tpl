{
  "passwordLogin": {
    "enabled": true
  },
  "oauth": {
    "enabled": true,
    "issuerUrl": "${issuer_url}",
    "clientId": "${client_id}",
    "clientSecret": "${client_secret}",
    "scope": "openid email profile",
    "signingAlgorithm": "RS256",
    "profileSigningAlgorithm": "none",
    "buttonText": "${button_text}",
    "autoRegister": true,
    "autoLaunch": false,
    "mobileOverrideEnabled": false,
    "mobileRedirectUri": "${mobile_redirect_uri}",
    "storageLabelClaim": "preferred_username",
    "storageQuotaClaim": "immich_quota",
    "defaultStorageQuota": 0,
    "roleClaim": "immich_role",
    "tokenEndpointAuthMethod": "client_secret_basic"
  }
}
