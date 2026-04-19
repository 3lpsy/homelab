{
  "realm": "thunderbolt",
  "enabled": true,
  "sslRequired": "external",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": false,
  "editUsernameAllowed": false,
  "bruteForceProtected": true,
  "clients": [
    {
      "clientId": "thunderbolt-app",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "${oidc_client_secret}",
      "redirectUris": ["${public_url}/*", "tauri://localhost/*", "http://tauri.localhost/*", "http://localhost:*/*"],
      "webOrigins": ["+"],
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "publicClient": false,
      "protocol": "openid-connect",
      "defaultClientScopes": ["openid", "profile", "email"]
    }
  ],
  "users": [
    {
      "username": "${admin_email}",
      "email": "${admin_email}",
      "firstName": "Admin",
      "lastName": "User",
      "enabled": true,
      "emailVerified": true,
      "credentials": [
        {
          "type": "password",
          "value": "${seed_user_password}",
          "temporary": false
        }
      ]
    }
  ]
}
