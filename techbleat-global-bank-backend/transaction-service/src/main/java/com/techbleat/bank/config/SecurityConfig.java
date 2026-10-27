package com.techbleat.bank.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.security.oauth2.server.resource.web.BearerTokenAuthenticationEntryPoint;
import org.springframework.security.oauth2.server.resource.web.access.BearerTokenAccessDeniedHandler;
import org.springframework.security.web.AuthenticationEntryPoint;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.access.AccessDeniedHandler;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

/**
 * Validates Keycloak access tokens on every request except /health.
 *
 * Signature (RS256 via the realm JWKS), expiry, issuer and audience are checked
 * here; roles and account ownership are checked on each controller method.
 * The bank user ID is the token's preferred_username claim, never a header,
 * path or body value supplied by the caller.
 */
@Configuration
@EnableMethodSecurity
public class SecurityConfig {

    private static final Logger securityLog = LoggerFactory.getLogger("security.audit");

    static final String USER_ID_CLAIM = "preferred_username";

    @Value("${banking.security.issuer}")
    private String issuer;

    @Value("${banking.security.jwk-set-uri}")
    private String jwkSetUri;

    @Value("${banking.security.audience}")
    private String audience;

    @Value("${banking.security.role-client-id}")
    private String roleClientId;

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
                // Bearer tokens only, no cookies or sessions, so CSRF protection does not apply.
                .csrf(csrf -> csrf.disable())
                .cors(Customizer.withDefaults())
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers(HttpMethod.GET, "/health").permitAll()
                        .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                        .anyRequest().authenticated())
                .oauth2ResourceServer(oauth -> oauth
                        .jwt(jwt -> jwt.jwtAuthenticationConverter(this::toAuthentication))
                        .authenticationEntryPoint(loggingEntryPoint())
                        .accessDeniedHandler(loggingAccessDeniedHandler()))
                .exceptionHandling(ex -> ex
                        .authenticationEntryPoint(loggingEntryPoint())
                        .accessDeniedHandler(loggingAccessDeniedHandler()));
        return http.build();
    }

    @Bean
    public JwtDecoder jwtDecoder() {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(jwkSetUri)
                .jwsAlgorithm(SignatureAlgorithm.RS256)
                .build();
        decoder.setJwtValidator(new DelegatingOAuth2TokenValidator<>(
                JwtValidators.createDefaultWithIssuer(issuer),
                audienceValidator(audience),
                requiredClaimValidator(USER_ID_CLAIM)));
        return decoder;
    }

    static OAuth2TokenValidator<Jwt> audienceValidator(String expectedAudience) {
        return jwt -> jwt.getAudience() != null && jwt.getAudience().contains(expectedAudience)
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(
                        new OAuth2Error("invalid_token", "The token audience is not accepted", null));
    }

    static OAuth2TokenValidator<Jwt> requiredClaimValidator(String claim) {
        return jwt -> jwt.hasClaim(claim) && !jwt.getClaimAsString(claim).isBlank()
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(
                        new OAuth2Error("invalid_token", "The token has no " + claim + " claim", null));
    }

    /** Maps Keycloak realm roles and roles of the configured client to ROLE_ authorities. */
    private AbstractAuthenticationToken toAuthentication(Jwt jwt) {
        List<GrantedAuthority> authorities = new ArrayList<>();
        addRoles(authorities, jwt.getClaimAsMap("realm_access"));
        Map<String, Object> resourceAccess = jwt.getClaimAsMap("resource_access");
        if (resourceAccess != null && resourceAccess.get(roleClientId) instanceof Map<?, ?> client) {
            addRoles(authorities, client);
        }
        return new JwtAuthenticationToken(jwt, authorities, jwt.getClaimAsString(USER_ID_CLAIM));
    }

    private static void addRoles(List<GrantedAuthority> authorities, Map<?, ?> access) {
        if (access != null && access.get("roles") instanceof Collection<?> roles) {
            roles.forEach(role -> authorities.add(new SimpleGrantedAuthority("ROLE_" + role)));
        }
    }

    // Denials are logged with the reason and caller, never the token itself.
    private AuthenticationEntryPoint loggingEntryPoint() {
        BearerTokenAuthenticationEntryPoint delegate = new BearerTokenAuthenticationEntryPoint();
        return (request, response, exception) -> {
            securityLog.warn("authentication_failed method={} path={} remote={} reason=\"{}\"",
                    request.getMethod(), request.getRequestURI(), request.getRemoteAddr(),
                    exception.getMessage());
            delegate.commence(request, response, exception);
        };
    }

    private AccessDeniedHandler loggingAccessDeniedHandler() {
        BearerTokenAccessDeniedHandler delegate = new BearerTokenAccessDeniedHandler();
        return (request, response, exception) -> {
            securityLog.warn("authorization_denied method={} path={} remote={} user={} subject={}",
                    request.getMethod(), request.getRequestURI(), request.getRemoteAddr(),
                    currentUser(), currentSubject());
            delegate.handle(request, response, exception);
        };
    }

    private static String currentUser() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        return auth == null ? "anonymous" : auth.getName();
    }

    private static String currentSubject() {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        return auth instanceof JwtAuthenticationToken jwtAuth ? jwtAuth.getToken().getSubject() : "unknown";
    }
}
