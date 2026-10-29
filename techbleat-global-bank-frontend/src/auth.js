import Keycloak from "keycloak-js";

// Runtime settings from /app-config.js (rendered by nginx from environment variables), so one
// image serves every environment; build-time Vite variables remain as a fallback for dev.
const runtime = window.APP_CONFIG || {};
const clientId = runtime.keycloakClientId || import.meta.env.VITE_KEYCLOAK_CLIENT_ID || "banking-frontend";
const keycloak = new Keycloak({
  url: runtime.keycloakUrl || import.meta.env.VITE_KEYCLOAK_URL || "http://localhost:8080",
  realm: runtime.keycloakRealm || import.meta.env.VITE_KEYCLOAK_REALM || "banking",
  clientId,
});

let initialization;

export function initializeAuth() {
  if (!initialization) {
    initialization = keycloak.init({
      onLoad: "check-sso",
      pkceMethod: "S256",
      checkLoginIframe: false,
    });
  }
  return initialization;
}

export function login() {
  return keycloak.login({ redirectUri: `${window.location.origin}/` });
}

export async function getAccessToken() {
  if (!keycloak.authenticated) {
    throw new Error("Your session has expired. Please sign in again.");
  }
  await keycloak.updateToken(30);
  return keycloak.token;
}

export function getIdentity() {
  return keycloak.tokenParsed || null;
}

export function hasRole(role) {
  if (!role || !keycloak.tokenParsed) return false;
  const claims = keycloak.tokenParsed;
  const realmRoles = claims.realm_access?.roles || [];
  const clientRoles = claims.resource_access?.[clientId]?.roles || [];
  return realmRoles.includes(role) || clientRoles.includes(role);
}

export function logout() {
  return keycloak.logout({ redirectUri: window.location.origin });
}