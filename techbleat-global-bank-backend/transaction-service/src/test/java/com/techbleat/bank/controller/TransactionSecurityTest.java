package com.techbleat.bank.controller;

import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.sun.net.httpserver.HttpServer;
import com.techbleat.bank.config.SecurityConfig;
import com.techbleat.bank.service.TransactionService;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyDouble;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Acceptance criteria A4 (token rejection) and A5 (cross-account denial).
 *
 * Tokens are signed with a throwaway RSA key served from a local JWKS endpoint,
 * so the production decoder (signature, expiry, issuer, audience) runs unchanged.
 */
@WebMvcTest(TransactionController.class)
@Import(SecurityConfig.class)
class TransactionSecurityTest {

    private static final String ISSUER = "https://idp.test/realms/banking";
    private static final String AUDIENCE = "banking-api";
    private static final String CUSTOMER = "banking-customer";
    private static final String TRANSACT = "banking-transact";

    private static final RSAKey SIGNING_KEY = rsaKey("trusted-key");
    private static final HttpServer JWKS_SERVER = startJwksServer();

    @Autowired
    private MockMvc mvc;

    @MockBean
    private TransactionService transactionService;

    @DynamicPropertySource
    static void securityProperties(DynamicPropertyRegistry registry) {
        registry.add("banking.security.issuer", () -> ISSUER);
        registry.add("banking.security.audience", () -> AUDIENCE);
        registry.add("banking.security.role-client-id", () -> "banking-frontend");
        registry.add("banking.security.jwk-set-uri",
                () -> "http://127.0.0.1:" + JWKS_SERVER.getAddress().getPort() + "/certs");
    }

    @AfterAll
    static void stopJwksServer() {
        JWKS_SERVER.stop(0);
    }

    // ---- A4: invalid tokens are rejected ------------------------------------------------------

    @Test
    void healthIsPublic() throws Exception {
        mvc.perform(get("/health")).andExpect(status().isOk());
    }

    @Test
    void missingTokenIsRejected() throws Exception {
        mvc.perform(get("/balance/alice")).andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void malformedTokenIsRejected() throws Exception {
        mvc.perform(get("/balance/alice").header("Authorization", "Bearer not-a-jwt"))
                .andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void expiredTokenIsRejected() throws Exception {
        String token = sign(SIGNING_KEY, claims("alice", ISSUER, AUDIENCE, List.of(CUSTOMER))
                .issueTime(Date.from(Instant.now().minusSeconds(3600)))
                .expirationTime(Date.from(Instant.now().minusSeconds(600)))
                .build());
        mvc.perform(withToken(get("/balance/alice"), token)).andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void tokenSignedByUntrustedKeyIsRejected() throws Exception {
        // Same key ID as the trusted key, different private key.
        String token = sign(rsaKey("trusted-key"), claims("alice", ISSUER, AUDIENCE, List.of(CUSTOMER)).build());
        mvc.perform(withToken(get("/balance/alice"), token)).andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void tamperedTokenIsRejected() throws Exception {
        String token = sign(SIGNING_KEY, claims("alice", ISSUER, AUDIENCE, List.of(CUSTOMER)).build());
        String forged = sign(rsaKey("x"), claims("bob", ISSUER, AUDIENCE, List.of(CUSTOMER)).build());
        String[] original = token.split("\\.");
        String[] payloadFromForged = forged.split("\\.");
        String tampered = original[0] + "." + payloadFromForged[1] + "." + original[2];
        mvc.perform(withToken(get("/balance/bob"), tampered)).andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void unsignedTokenIsRejected() throws Exception {
        String unsigned = new com.nimbusds.jwt.PlainJWT(
                claims("alice", ISSUER, AUDIENCE, List.of(CUSTOMER)).build()).serialize();
        mvc.perform(withToken(get("/balance/alice"), unsigned)).andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void wrongIssuerIsRejected() throws Exception {
        String token = sign(SIGNING_KEY,
                claims("alice", "https://evil.test/realms/banking", AUDIENCE, List.of(CUSTOMER)).build());
        mvc.perform(withToken(get("/balance/alice"), token)).andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void wrongAudienceIsRejected() throws Exception {
        String token = sign(SIGNING_KEY, claims("alice", ISSUER, "account", List.of(CUSTOMER)).build());
        mvc.perform(withToken(get("/balance/alice"), token)).andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void tokenWithoutUsernameIsRejected() throws Exception {
        JWTClaimsSet noUsername = new JWTClaimsSet.Builder(
                claims("alice", ISSUER, AUDIENCE, List.of(CUSTOMER)).build())
                .claim("preferred_username", null)
                .build();
        mvc.perform(withToken(get("/balance/alice"), sign(SIGNING_KEY, noUsername)))
                .andExpect(status().isUnauthorized());
        verifyNoInteractions(transactionService);
    }

    @Test
    void tokenWithoutCustomerRoleIsForbidden() throws Exception {
        String token = token("alice", List.of());
        mvc.perform(withToken(get("/balance/alice"), token)).andExpect(status().isForbidden());
        verifyNoInteractions(transactionService);
    }

    @Test
    void customerWithoutTransactRoleCannotMoveMoney() throws Exception {
        String token = token("alice", List.of(CUSTOMER));
        mvc.perform(withToken(post("/transactions/withdraw"), token)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"amount\": 10}"))
                .andExpect(status().isForbidden());
        mvc.perform(withToken(post("/transactions/transfer"), token)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"toUserId\": \"bob\", \"amount\": 10}"))
                .andExpect(status().isForbidden());
        mvc.perform(withToken(post("/transactions/deposit"), token)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"amount\": 10}"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(transactionService);
    }

    @Test
    void clientRolesFromTheFrontendClientAreAccepted() throws Exception {
        when(transactionService.getBalance("alice")).thenReturn(5.0);
        JWTClaimsSet clientRoles = new JWTClaimsSet.Builder(claims("alice", ISSUER, AUDIENCE, List.of()).build())
                .claim("resource_access", Map.of("banking-frontend", Map.of("roles", List.of(CUSTOMER))))
                .build();
        mvc.perform(withToken(get("/balance/alice"), sign(SIGNING_KEY, clientRoles)))
                .andExpect(status().isOk());
    }

    @Test
    void rolesFromOtherClientsAreIgnored() throws Exception {
        JWTClaimsSet otherClient = new JWTClaimsSet.Builder(claims("alice", ISSUER, AUDIENCE, List.of()).build())
                .claim("resource_access", Map.of("some-other-app", Map.of("roles", List.of(CUSTOMER))))
                .build();
        mvc.perform(withToken(get("/balance/alice"), sign(SIGNING_KEY, otherClient)))
                .andExpect(status().isForbidden());
        verifyNoInteractions(transactionService);
    }

    // ---- A5: cross-account access is denied --------------------------------------------------

    @Test
    void ownerCanReadOwnBalance() throws Exception {
        when(transactionService.getBalance("alice")).thenReturn(42.0);
        mvc.perform(withToken(get("/balance/alice"), token("alice", List.of(CUSTOMER))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.userId").value("alice"))
                .andExpect(jsonPath("$.balance").value(42.0));
    }

    @Test
    void cannotReadAnotherCustomersBalance() throws Exception {
        mvc.perform(withToken(get("/balance/bob"), token("alice", List.of(CUSTOMER))))
                .andExpect(status().isForbidden());
        verifyNoInteractions(transactionService);
    }

    @Test
    void cannotReadAnotherCustomersTransactions() throws Exception {
        mvc.perform(withToken(get("/transactions/bob"), token("alice", List.of(CUSTOMER))))
                .andExpect(status().isForbidden());
        verifyNoInteractions(transactionService);
    }

    @Test
    void cannotWithdrawFromAnotherAccountBySpoofingHeader() throws Exception {
        mvc.perform(withToken(post("/transactions/withdraw"), token("alice", List.of(CUSTOMER, TRANSACT)))
                        .header("X-User-Id", "bob")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"amount\": 10}"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(transactionService);
    }

    @Test
    void cannotTransferOutOfAnotherAccountBySpoofingHeader() throws Exception {
        mvc.perform(withToken(post("/transactions/transfer"), token("alice", List.of(CUSTOMER, TRANSACT)))
                        .header("X-User-Id", "bob")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"toUserId\": \"alice\", \"amount\": 10}"))
                .andExpect(status().isForbidden());
        verifyNoInteractions(transactionService);
    }

    @Test
    void writesAlwaysActOnTheTokenUser() throws Exception {
        when(transactionService.withdraw(anyString(), anyDouble())).thenReturn(Map.of("balance", 0.0));
        when(transactionService.transfer(anyString(), anyString(), anyDouble(), any()))
                .thenReturn(Map.of("fromBalance", 0.0));
        String token = token("alice", List.of(CUSTOMER, TRANSACT));

        mvc.perform(withToken(post("/transactions/withdraw"), token)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"amount\": 10}"))
                .andExpect(status().isOk());
        mvc.perform(withToken(post("/transactions/transfer"), token)
                        .contentType(MediaType.APPLICATION_JSON).content("{\"toUserId\": \"bob\", \"amount\": 10}"))
                .andExpect(status().isOk());

        verify(transactionService).withdraw("alice", 10.0);
        verify(transactionService).transfer("alice", "bob", 10.0, null);
    }

    @Test
    void formEncodedWritesAreNotAccepted() throws Exception {
        mvc.perform(withToken(post("/transactions/withdraw"), token("alice", List.of(CUSTOMER, TRANSACT)))
                        .contentType(MediaType.APPLICATION_FORM_URLENCODED).content("amount=10"))
                .andExpect(status().isUnsupportedMediaType());
        verifyNoInteractions(transactionService);
    }

    // ---- helpers ------------------------------------------------------------------------------

    private static String token(String username, List<String> realmRoles) {
        return sign(SIGNING_KEY, claims(username, ISSUER, AUDIENCE, realmRoles).build());
    }

    private static JWTClaimsSet.Builder claims(String username, String issuer, String audience, List<String> realmRoles) {
        Instant now = Instant.now();
        return new JWTClaimsSet.Builder()
                .issuer(issuer)
                .subject(UUID.randomUUID().toString())
                .audience(List.of(audience))
                .issueTime(Date.from(now))
                .expirationTime(Date.from(now.plusSeconds(300)))
                .claim("preferred_username", username)
                .claim("realm_access", Map.of("roles", realmRoles));
    }

    private static String sign(RSAKey key, JWTClaimsSet claims) {
        try {
            SignedJWT jwt = new SignedJWT(
                    new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).type(JOSEObjectType.JWT).build(),
                    claims);
            jwt.sign(new RSASSASigner(key));
            return jwt.serialize();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static MockHttpServletRequestBuilder withToken(MockHttpServletRequestBuilder request, String token) {
        return request.header("Authorization", "Bearer " + token);
    }

    private static RSAKey rsaKey(String keyId) {
        try {
            return new RSAKeyGenerator(2048).keyID(keyId).generate();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static HttpServer startJwksServer() {
        try {
            byte[] body = new JWKSet(SIGNING_KEY.toPublicJWK()).toString().getBytes(StandardCharsets.UTF_8);
            HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            server.createContext("/certs", exchange -> {
                exchange.getResponseHeaders().add("Content-Type", "application/json");
                exchange.sendResponseHeaders(200, body.length);
                exchange.getResponseBody().write(body);
                exchange.close();
            });
            server.start();
            return server;
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
