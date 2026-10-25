// ==============================================================================
// Server-Side Outbound Gateway Alternative Method for Cloudflare, Amazon & LinkedIn
// ==============================================================================
// Instead of putting 296 CIDR ranges into WireGuard client configurations (which bloats client rules
// and causes mobile/client instability), WireGuard client profiles remain 100% clean and standard
// with AllowedIPs = 0.0.0.0/0.
//
// All anti-flag, anti-datacenter block, and unblocking magic happens on the VPS server side via:
// 1. Server-Side Cloudflare WARP Outbound Gateway / Edge Relay.
// 2. Server-Side Anti-Fragmentation TCP MSS 1240 Clamping & TTL=64 Normalization.
// 3. EDNS Client-Subnet (ECS) Stripping & Smart Anycast DNS.

export const CLOUDFLARE_BYPASS_CIDRS: string[] = [
  '0.0.0.0/0',
];

export const CLOUDFLARE_BYPASS_ALLOWED_IPS_STRING = '0.0.0.0/0, ::/0';

/**
 * Format AllowedIPs for WireGuard client configuration.
 * Generates clean standard AllowedIPs = 0.0.0.0/0 for 100% compatibility with all WireGuard clients
 * (iOS, Android, Windows, macOS, Linux, GL.iNet) without any client add-ons.
 */
export function formatWireguardAllowedIps(_cidrs: string[] = CLOUDFLARE_BYPASS_CIDRS, hasIpv6: boolean = false): string {
  return hasIpv6 ? 'AllowedIPs = 0.0.0.0/0, ::/0' : 'AllowedIPs = 0.0.0.0/0';
}
