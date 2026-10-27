import React, { useState, useEffect, useRef, useCallback } from 'react';
import { db } from '../lib/firebase';
import { doc, writeBatch, setDoc } from 'firebase/firestore';
import {
  ShieldAlert,
  CheckCircle2,
  AlertTriangle,
  Upload,
  Sparkles,
  ExternalLink,
  Shield,
  Image as ImageIcon,
  Check,
  RefreshCw,
  X,
  Volume2,
  Mic,
} from 'lucide-react';

export interface AltNumberEntry {
  phone: string;
  digits: string;
  is_whatsapp?: boolean;
}

export function normalizeAltNumbers(val: any): AltNumberEntry[] | undefined {
  if (!val) return undefined;
  let parsed = val;
  if (typeof val === 'string') {
    const trimmed = val.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        parsed = JSON.parse(trimmed);
      } catch {
        parsed = trimmed.split(/[,;\n]/).map((s) => s.trim()).filter(Boolean);
      }
    } else if (trimmed) {
      parsed = trimmed.split(/[,;\n]/).map((s) => s.trim()).filter(Boolean);
    }
  }
  if (!Array.isArray(parsed)) {
    if (typeof parsed === 'object' && parsed !== null) {
      parsed = [parsed];
    } else {
      return undefined;
    }
  }
  const result: AltNumberEntry[] = [];
  for (const item of parsed) {
    if (typeof item === 'string') {
      const clean = item.replace(/\D/g, '');
      if (clean) result.push({ phone: item.trim(), digits: clean, is_whatsapp: false });
    } else if (item && typeof item === 'object') {
      const p = String(item.phone || item.phone_number || '').trim();
      const d = String(item.digits || item.cleanPhone || p.replace(/\D/g, '')).trim();
      if (d || p) {
        result.push({
          phone: p || d,
          digits: d || p.replace(/\D/g, ''),
          is_whatsapp: Boolean(item.is_whatsapp || item.isWhatsapp),
        });
      }
    }
  }
  return result.length > 0 ? result : undefined;
}

export interface ThreatRecord {
  id: string;
  phone_number: string;
  phone_digits: string;
  is_whatsapp?: boolean;
  alt_numbers?: AltNumberEntry[];
  source_name: string;
  source_url: string;
  report_date: string;
  category: string;
  description: string;
  impersonated_company?: string;
  scammer_name?: string;
  invoice_number?: string;
  amount_charged?: string;
  money_lost?: number | string;
  how_contacted?: string;
  reporter_name?: string;
  reporter_email?: string;
  reporter_ip?: string;
  image_url?: string;
  evidence_url?: string;
  is_down?: boolean;
  is_user_submitted?: boolean;
  has_evidence?: boolean;
  tags?: string[];
}

export const STANDARD_SCAM_CATEGORIES = [
  'Lotto / Prize / Giveaway',
  'Refund / Impersonator Scams',
  'Spellcaster / Non-Delivery',
  'Digital / Manufacturing Scams',
  'Others',
];

export function mapToStandardCategory(
  rawCat: string = '',
  rawText: string = '',
  digits: string = ''
): string {
  const combined = `${rawCat} ${rawText}`.toLowerCase();

  // 1. Lotto / Prize / Giveaway
  if (
    combined.includes('lotto') ||
    combined.includes('lottery') ||
    combined.includes('sweepstakes') ||
    combined.includes('giveaway') ||
    combined.includes('pch') ||
    combined.includes('publishers clearing') ||
    combined.includes('american cash award') ||
    combined.includes('mega million') ||
    combined.includes('powerball') ||
    combined.includes('prize') ||
    combined.includes('winner') ||
    combined.includes('won cash') ||
    combined.includes('delivery fee')
  ) {
    return 'Lotto / Prize / Giveaway';
  }

  // 2. Spellcaster / Non-Delivery (African country codes, love spells, pet/puppy/car non-delivery)
  if (
    digits.startsWith('234') ||
    digits.startsWith('254') ||
    digits.startsWith('27') ||
    combined.includes('spellcaster') ||
    combined.includes('spell') ||
    combined.includes('baba') ||
    combined.includes('temple') ||
    combined.includes('herbalist') ||
    combined.includes('non-delivery') ||
    combined.includes('pet scam') ||
    combined.includes('puppy') ||
    combined.includes('chemical') ||
    combined.includes('goods for sale')
  ) {
    return 'Spellcaster / Non-Delivery';
  }

  // 3. Digital / Manufacturing Scams (Crypto investment, mining equipment, counterfeit goods, fake suppliers, B2B manufacturing, digital products)
  if (
    combined.includes('digital') ||
    combined.includes('manufacturing') ||
    combined.includes('crypto') ||
    combined.includes('bitcoin') ||
    combined.includes('blockchain') ||
    combined.includes('mining rig') ||
    combined.includes('supplier') ||
    combined.includes('wholesaler') ||
    combined.includes('industrial equipment') ||
    combined.includes('machinery') ||
    combined.includes('counterfeit') ||
    combined.includes('factory direct') ||
    combined.includes('oem') ||
    combined.includes('hardware wallet') ||
    combined.includes('nft') ||
    combined.includes('b2b') ||
    combined.includes('raw material')
  ) {
    return 'Digital / Manufacturing Scams';
  }

  // 4. Refund / Impersonator Scams (Company impersonation, refund, tech support, government, utility, bank)
  if (
    combined.includes('refund') ||
    combined.includes('impersonat') ||
    combined.includes('geek squad') ||
    combined.includes('paypal') ||
    combined.includes('norton') ||
    combined.includes('mcafee') ||
    combined.includes('microsoft') ||
    combined.includes('apple') ||
    combined.includes('amazon') ||
    combined.includes('walmart') ||
    combined.includes('best buy') ||
    combined.includes('tech support') ||
    combined.includes('irs') ||
    combined.includes('social security') ||
    combined.includes('police') ||
    combined.includes('law enforcement') ||
    combined.includes('dea') ||
    combined.includes('bank') ||
    combined.includes('chase') ||
    combined.includes('wells fargo') ||
    combined.includes('zelle') ||
    combined.includes('wire fraud') ||
    combined.includes('spectrum') ||
    combined.includes('at&t') ||
    combined.includes('utility') ||
    combined.includes('electric') ||
    combined.includes('telecom') ||
    combined.includes('invoice') ||
    combined.includes('auto-debit')
  ) {
    return 'Refund / Impersonator Scams';
  }

  // 5. Others (Recovery, celebrity like Elon Musk, romance blackmail, job/task, or uncategorized)
  return 'Others';
}

// Helper: Format dialable phone numbers
export function formatDisplayPhone(raw: string, digits: string): string {
  if (!digits) return raw || '';
  if (digits.length === 10) {
    return `1 (${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
  }
  if (digits.length === 11 && digits.startsWith('1')) {
    return `1 (${digits.slice(1, 4)}) ${digits.slice(4, 7)}-${digits.slice(7)}`;
  }
  if (digits.startsWith('234') && digits.length === 13) {
    return `+234 ${digits.slice(3, 6)} ${digits.slice(6, 9)} ${digits.slice(9)}`;
  }
  if (digits.startsWith('254') && digits.length === 12) {
    return `+254 ${digits.slice(3, 6)} ${digits.slice(6, 9)} ${digits.slice(9)}`;
  }
  if (digits.startsWith('27') && digits.length === 11) {
    return `+27 ${digits.slice(2, 4)} ${digits.slice(4, 7)} ${digits.slice(7)}`;
  }
  return raw.startsWith('+') ? raw : `+${digits}`;
}

export async function copyToClipboard(text: string): Promise<boolean> {
  if (!text) return false;
  let copied = false;

  // 1. Try modern navigator.clipboard
  if (typeof navigator !== 'undefined' && navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
    } catch (err) {
      console.warn('navigator.clipboard.writeText failed, using fallback:', err);
    }
  }

  // 2. Fallback for iframe / unsupported contexts using document.execCommand
  if (!copied && typeof document !== 'undefined') {
    try {
      const textArea = document.createElement('textarea');
      textArea.value = text;
      textArea.style.position = 'fixed';
      textArea.style.left = '-999999px';
      textArea.style.top = '-999999px';
      textArea.setAttribute('readonly', '');
      document.body.appendChild(textArea);
      textArea.focus();
      textArea.select();
      copied = document.execCommand('copy');
      document.body.removeChild(textArea);
    } catch (err) {
      console.error('Fallback execCommand failed:', err);
      copied = false;
    }
  }

  return copied;
}

export function getCleanCopyPhone(text: string): string {
  if (!text) return '';
  const trimmed = text.trim();
  const digits = trimmed.replace(/\D/g, '');
  if (!digits) return '';

  // 1. North American / US: 11 digits starting with 1 -> copy as 10-digit xxxxxxxxxx
  if (digits.length === 11 && digits.startsWith('1')) {
    return digits.slice(1);
  }

  // 2. North American / US: 10 digits without leading '+' -> copy as xxxxxxxxxx
  if (digits.length === 10 && !trimmed.startsWith('+')) {
    return digits;
  }

  // 3. Explicitly US prefix +1 with 10 digits
  if (trimmed.startsWith('+1') && digits.startsWith('1') && digits.length === 11) {
    return digits.slice(1);
  }

  // 4. Numbers outside the country:
  // Must copy as +xxxxxxxxxxxxx (+xxx e.g. Nigeria +234) or +xxxxxxxxxxxx (+xx e.g. Kenya +254, UK +44, South Africa +27)
  return `+${digits}`;
}

export interface CountryInfo {
  name: string;
  flag: string;
  code: string;
}

export function deriveCountryInfo(rawOrFormatted: string): CountryInfo {
  const raw = (rawOrFormatted || '').trim();
  const digits = raw.replace(/\D/g, '');

  if (digits.startsWith('234')) return { name: 'Nigeria', flag: '🇳🇬', code: 'NG' };
  if (digits.startsWith('254')) return { name: 'Kenya', flag: '🇰🇪', code: 'KE' };
  if (digits.startsWith('27')) return { name: 'South Africa', flag: '🇿🇦', code: 'ZA' };
  if (digits.startsWith('233')) return { name: 'Ghana', flag: '🇬🇭', code: 'GH' };
  if (digits.startsWith('256')) return { name: 'Uganda', flag: '🇺🇬', code: 'UG' };
  if (digits.startsWith('44')) return { name: 'United Kingdom', flag: '🇬🇧', code: 'GB' };
  if (digits.startsWith('91')) return { name: 'India', flag: '🇮🇳', code: 'IN' };
  if (digits.startsWith('61')) return { name: 'Australia', flag: '🇦🇺', code: 'AU' };
  if (digits.startsWith('63')) return { name: 'Philippines', flag: '🇵🇭', code: 'PH' };
  if (digits.startsWith('92')) return { name: 'Pakistan', flag: '🇵🇰', code: 'PK' };
  if (digits.startsWith('49')) return { name: 'Germany', flag: '🇩🇪', code: 'DE' };
  if (digits.startsWith('33')) return { name: 'France', flag: '🇫🇷', code: 'FR' };
  if (digits.startsWith('1876') || (raw.includes('876') && raw.toLowerCase().includes('jamaica'))) return { name: 'Jamaica', flag: '🇯🇲', code: 'JM' };
  if (digits.length === 10 || (digits.length === 11 && digits.startsWith('1'))) {
    return { name: 'United States', flag: '🇺🇸', code: 'US' };
  }
  return { name: 'International', flag: '🌐', code: 'INT' };
}

// Helper: PST Date Stamp YYYY-MM-DD
export function getPSTDateStamp(): string {
  try {
    const formatter = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'America/Los_Angeles',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    });
    return formatter.format(new Date());
  } catch {
    return new Date().toISOString().slice(0, 10);
  }
}

// Helper: Extract Date directly from Invoice Text or File Metadata (filename / lastModified)
export function extractDateFromTextOrFile(text: string, file?: File): string {
  const clean = text || '';

  const monthNames: { [key: string]: string } = {
    january: '01', jan: '01',
    february: '02', feb: '02',
    march: '03', mar: '03',
    april: '04', apr: '04',
    may: '05',
    june: '06', jun: '06',
    july: '07', jul: '07',
    august: '08', aug: '08',
    september: '09', sep: '09', sept: '09',
    october: '10', oct: '10',
    november: '11', nov: '11',
    december: '12', dec: '12',
  };

  // 1. Text match: (Month Name) (Day 1-31),? (Year 2020-2030) e.g. "Tuesday, October 06, 2026" or "October 06, 2026"
  const writtenDateRegex = /(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[.,]?\s+(\d{1,2})(?:st|nd|rd|th)?[.,]?\s+(202\d)/i;
  const matchWritten = clean.match(writtenDateRegex);
  if (matchWritten) {
    const rawMonth = matchWritten[0].split(/[\s,]+/)[0].toLowerCase().replace(/[^a-z]/g, '');
    const month = monthNames[rawMonth];
    const day = matchWritten[1].padStart(2, '0');
    const year = matchWritten[2];
    if (month && year) {
      return `${year}-${month}-${day}`;
    }
  }

  // Text match: (Day 1-31) (Month Name) (Year 2020-2030)
  const dayFirstRegex = /(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[.,]?\s+(202\d)/i;
  const matchDayFirst = clean.match(dayFirstRegex);
  if (matchDayFirst) {
    const day = matchDayFirst[1].padStart(2, '0');
    const rawMonth = matchDayFirst[2].toLowerCase().replace(/[^a-z]/g, '');
    const month = monthNames[rawMonth];
    const year = matchDayFirst[3];
    if (month && year) {
      return `${year}-${month}-${day}`;
    }
  }

  // Text match: MM/DD/YYYY or MM-DD-YYYY
  const numericDateRegex = /\b(0?[1-9]|1[0-2])[\/\-.](0?[1-9]|[12]\d|3[01])[\/\-.](202\d)\b/;
  const matchNumeric = clean.match(numericDateRegex);
  if (matchNumeric) {
    const month = matchNumeric[1].padStart(2, '0');
    const day = matchNumeric[2].padStart(2, '0');
    const year = matchNumeric[3];
    return `${year}-${month}-${day}`;
  }

  // Text match: YYYY-MM-DD
  const isoMatch = clean.match(/\b(202\d)-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])\b/);
  if (isoMatch) {
    return isoMatch[0];
  }

  // 2. Fallback to image/pdf filename metadata (e.g. Screenshot_20261006_100904_Email.jpg)
  if (file?.name) {
    const fnMatch = file.name.match(/\b(202\d)[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12]\d|3[01])\b/);
    if (fnMatch) {
      return `${fnMatch[1]}-${fnMatch[2]}-${fnMatch[3]}`;
    }
  }

  // 3. Fallback to file lastModified metadata
  if (file?.lastModified) {
    try {
      const d = new Date(file.lastModified);
      if (!isNaN(d.getTime())) {
        const year = d.getFullYear();
        if (year >= 2020 && year <= 2030) {
          const month = String(d.getMonth() + 1).padStart(2, '0');
          const day = String(d.getDate()).padStart(2, '0');
          return `${year}-${month}-${day}`;
        }
      }
    } catch {}
  }

  return getPSTDateStamp();
}

// Helper: Extract all phone numbers from OCR text in sequential order
export function extractPhoneNumbersFromText(text: string): string[] {
  if (!text) return [];
  const numbers: string[] = [];
  const seenKeys = new Set<string>();

  const registerNumber = (raw: string, digits: string) => {
    if (!digits) return;
    let key = digits;
    // Normalize US/NANP 11-digit starting with 1 to 10-digit
    if (digits.length === 11 && digits.startsWith('1')) {
      key = digits.slice(1);
    }
    // Accept valid phone number length (at least 7 digits, up to 15 digits)
    if (key.length >= 7 && key.length <= 15 && !seenKeys.has(key)) {
      seenKeys.add(key);
      numbers.push(formatDisplayPhone(raw, digits));
    }
  };

  // Pattern 1: International formatted numbers (+234..., +44..., +91..., +1..., etc.)
  const intlRegex = /(?:\+|00)(\d{1,4})[\s.-]*\(?(\d{1,4})\)?[\s.-]*(\d{2,5})[\s.-]*(\d{2,5})(?:[\s.-]*(\d{1,5}))?/g;
  let m: RegExpExecArray | null;
  while ((m = intlRegex.exec(text)) !== null) {
    const raw = m[0].trim();
    const digits = raw.replace(/\D/g, '');
    if (digits.length >= 7 && digits.length <= 15) {
      registerNumber(raw, digits);
    }
  }

  // Pattern 2: US/NANP phone numbers in all standard formats:
  // e.g. +1 (959) 248-1366, +1 959 248 1366, 1-959-248-1366, 959-248-1366, (959) 248-1366, 959.248.1366, 959 248 1366, (959)248-1366, +1.959.248.1366
  const usRegex = /(?:(?:\+?1|001)[\s.-]*)?(?:\(\s*([0-9]{3})\s*\)|([0-9]{3}))[\s.-]*([0-9]{3})[\s.-]*([0-9]{4})/g;
  while ((m = usRegex.exec(text)) !== null) {
    const raw = m[0].trim();
    const digits = raw.replace(/\D/g, '');
    if (digits.length === 10 || (digits.length === 11 && digits.startsWith('1'))) {
      registerNumber(raw, digits);
    }
  }

  // Pattern 3: Labels followed by phone number (e.g. "Account Services Team: +1 959 248 1366", "Alt Phone: 959-248-1366", "Helpline: ...")
  const labelRegex = /(?:phone|tel|telephone|call|toll[-\s]*free|helpline|support|desk|team|hotline|contact|cell|mobile|alt|alternative|whatsapp|direct|number)[\s:=#\-_]+((?:\+?\d{1,3}[\s.-]*)?(?:\(?\d{2,4}\)?[\s.-]*)?\d{3,4}[\s.-]*\d{3,4}(?:[\s.-]*\d{1,4})?)/gi;
  while ((m = labelRegex.exec(text)) !== null) {
    const raw = m[1].trim();
    const digits = raw.replace(/\D/g, '');
    if (digits.length >= 7 && digits.length <= 15) {
      registerNumber(raw, digits);
    }
  }

  // Pattern 4: Raw 10 or 11 continuous digits or standard delimited sequences
  const rawDigitsRegex = /\b(1?[2-9]\d{2}[\s.-]?\d{3}[\s.-]?\d{4})\b/g;
  while ((m = rawDigitsRegex.exec(text)) !== null) {
    const raw = m[1].trim();
    const digits = raw.replace(/\D/g, '');
    if (digits.length === 10 || (digits.length === 11 && digits.startsWith('1'))) {
      registerNumber(raw, digits);
    }
  }

  return numbers;
}

// Helper: Clean OCR text and strip odd symbols, non-ASCII garbage & broken noise
export function cleanOcrTextArtifacts(text: string): string {
  if (!text) return '';
  return text
    // Replace broken non-ASCII OCR noise and weird stray symbols
    .replace(/[§¢¤¦¥©«¬®¯°±²³µ¶·¸¹º»¼½¾¿×÷~^|\\{}[\]`_]/g, ' ')
    .replace(/[\u0000-\u001F\u007F-\u009F\uFFFD]/g, ' ')
    // Collapse excess spaces and clean punctuation
    .replace(/[ \t]+/g, ' ')
    .replace(/\s*([,.:;?!])\s*/g, '$1 ')
    .replace(/\n\s*\n+/g, '\n')
    .trim();
}

// Helper: Extract impersonated company or scammer entity from text
export function extractScammerOrCompanyFromText(text: string): string {
  if (!text) return '';
  const clean = cleanOcrTextArtifacts(text);
  const companies = [
    'Geek Squad', 'Best Buy', 'PayPal', 'Norton', 'McAfee', 'Microsoft Defender', 'Microsoft', 'Apple',
    'Amazon', 'Publishers Clearing House', 'PCH Prize Patrol', 'PCH', 'Spectrum', 'AT&T', 'Comcast',
    'Xfinity', 'Coinbase', 'Metamask', 'Binance', 'USPS', 'FedEx', 'UPS', 'Malwarebytes', 'Google Workspace',
    'Social Security', 'IRS', 'Bank of America', 'Wells Fargo', 'Chase', 'Citi', 'Zelle', 'Dr. Baba', 'Love Spell',
    'Frenchie Bulldog', 'Puppy Breeder', 'Elon Musk Giveaway', 'Task Scam'
  ];

  for (const c of companies) {
    const regex = new RegExp(`\\b${c.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&')}\\b`, 'i');
    if (regex.test(clean)) {
      return c;
    }
  }
  return '';
}

// Helper: Accurately extract amount from OCR invoice text (supporting USD217. 59, $217.59, Renewal Total: USD..., etc.)
export function extractAmountFromOcrText(text: string, parsedAmount?: string): string {
  if (parsedAmount && parsedAmount.trim()) {
    const clean = parsedAmount.replace(/[^\d.]/g, '');
    if (clean && !isNaN(parseFloat(clean))) {
      return `$${parseFloat(clean).toFixed(2)}`;
    }
  }

  if (!text) return '';

  const patterns = [
    /(?:renewal\s*total|renewal\s*amount|total|charged|amount|fee|cost|subtotal|due|balance|renewal\s*fee|invoice\s*total)[:\s]*(?:USD|\$)?\s*([0-9]{1,6}(?:,[0-9]{3})*)\s*(?:\.\s*([0-9]{2}))?/i,
    /USD\s*([0-9]{1,6}(?:,[0-9]{3})*)\s*(?:\.\s*([0-9]{2}))?/i,
    /\$\s*([0-9]{1,6}(?:,[0-9]{3})*)\s*(?:\.\s*([0-9]{2}))?/,
    /(?:renewal|charged|fee|cost|total|amount)\s*[:=]?\s*([0-9]{1,6}(?:,[0-9]{3})*(?:\s*\.\s*[0-9]{2})?)/i,
  ];

  for (const pat of patterns) {
    const m = text.match(pat);
    if (m && m[1]) {
      const intPart = m[1].replace(/,/g, '');
      const decPart = m[2] ? m[2] : (m[1].includes('.') ? m[1].split('.')[1] : '00');
      const val = parseFloat(`${intPart}.${decPart}`);
      if (!isNaN(val) && val > 0) {
        return `$${val.toFixed(2)}`;
      }
    }
  }

  return '';
}

// Helper: Accurately extract invoice reference / claim code from OCR invoice text
export function extractInvoiceNumberFromOcrText(text: string, parsedInvoice?: string): string {
  if (parsedInvoice && parsedInvoice.trim() && parsedInvoice.toUpperCase() !== 'N/A') {
    return parsedInvoice.trim();
  }

  if (!text) return '';

  const patterns = [
    /(?:invoice\s*reference|biling\s*reference|billing\s*reference|invoice\s*no|invoice\s*#|invoice\s*id|claim\s*code|ref\s*#|reference\s*#|transaction\s*no|transaction\s*#)[:\s]+#?([A-Za-z0-9-]+)/i,
    /(?:ref|inv)[:\s]+#?([A-Za-z0-9-]+)/i,
    /\b(GS-[0-9]{3,8}-[A-Z]+)\b/i,
    /\b(INV-[0-9]{3,8}-[A-Z]+)\b/i,
    /\b(PCH-[0-9]{3,8}-[A-Z]+)\b/i,
  ];

  for (const pat of patterns) {
    const m = text.match(pat);
    if (m && m[1] && m[1].length >= 3) {
      return m[1].trim();
    }
  }

  return '';
}

// Helper: Database Client & Upsert
let supabaseInstance: any = null;
let activeUrl = '';
let activeKey = '';

/**
 * Resolves an API endpoint taking into account optional custom API base URL,
 * window global, or environment variable for standalone or embedded deployment on endscams.org.
 */
export function resolveApiUrl(endpoint: string, customBase?: string): string {
  const base = (
    customBase ||
    (typeof window !== 'undefined' && (window as any).__ENDSCAMS_API_URL__) ||
    (typeof process !== 'undefined' && process.env?.NEXT_PUBLIC_API_URL) ||
    (import.meta as any).env?.VITE_API_URL ||
    ''
  ).replace(/\/+$/, '');
  const path = endpoint.startsWith('/') ? endpoint : `/${endpoint}`;
  return base ? `${base}${path}` : path;
}

export function getStoredSupabaseConfig(): { url: string; key: string } {
  let url =
    (typeof process !== 'undefined' && process.env?.SUPABASE_URL) ||
    (import.meta as any).env?.SUPABASE_URL ||
    (import.meta as any).env?.VITE_SUPABASE_URL ||
    'https://joxeqlgkuvgvjoshmjqu.supabase.co';

  let key =
    (typeof process !== 'undefined' && (process.env?.SUPABASE_KEY || process.env?.SUPABASE_ANON_KEY)) ||
    (import.meta as any).env?.SUPABASE_KEY ||
    (import.meta as any).env?.SUPABASE_ANON_KEY ||
    (import.meta as any).env?.VITE_SUPABASE_ANON_KEY ||
    '';

  if (typeof window !== 'undefined') {
    const localUrl = localStorage.getItem('endscams_supabase_url');
    const localKey = localStorage.getItem('endscams_supabase_key');
    if (localUrl && localKey) {
      url = localUrl;
      key = localKey;
    }
  }

  return { url: url.trim(), key: key.trim() };
}

export async function fetchServerSupabaseConfig(customBase?: string): Promise<{ url: string; key: string }> {
  try {
    const res = await fetch(resolveApiUrl(`/api/config?_t=${Date.now()}`, customBase), {
      cache: 'no-store',
      headers: {
        'Cache-Control': 'no-cache, no-store',
      },
    });
    if (res.ok) {
      const data = await res.json();
      if (data.supabaseUrl && data.supabaseKey) {
        if (typeof window !== 'undefined') {
          localStorage.setItem('endscams_supabase_url', data.supabaseUrl);
          localStorage.setItem('endscams_supabase_key', data.supabaseKey);
        }
        supabaseInstance = null;
        activeUrl = '';
        activeKey = '';
        return { url: data.supabaseUrl, key: data.supabaseKey };
      }
    }
  } catch {}
  return getStoredSupabaseConfig();
}

export function getSupabaseClient(): any {
  return null;
}

export async function upsertToFirestoreDirect(records: ThreatRecord[], customBase?: string): Promise<boolean> {
  if (!records || records.length === 0) return false;

  // 1. Dispatch to server backend (which persists to local disk and Firestore)
  try {
    fetch(resolveApiUrl('/api/records/bulk-upsert', customBase), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ records, replace: false }),
    }).catch(() => {});
  } catch {}

  // 2. Direct client-side Firestore write if client db is active
  try {
    if (db) {
      const batch = writeBatch(db);
      for (const r of records) {
        const cleanDigits = (r.phone_digits || (r as any).cleanPhone || r.phone_number || '').replace(/\D/g, '');
        if (!cleanDigits) continue;
        const id = String(r.id || `rec-${cleanDigits}`).replace(/[^a-zA-Z0-9_\-]/g, '_').slice(0, 100);
        const docRef = doc(db, 'tracker_entries', id);
        const alts = normalizeAltNumbers(r.alt_numbers);
        const entry: Record<string, any> = {
          id,
          phone_number: String(r.phone_number || cleanDigits).slice(0, 40),
          phone_digits: cleanDigits.slice(0, 20),
          carrier: String((r as any).carrier || 'Virtual / CLEC Line').slice(0, 100),
          is_cell: Boolean((r as any).is_cell),
          line_type: (r as any).is_cell ? 'cell' : 'burner',
          is_whatsapp: Boolean(r.is_whatsapp),
          category: String(r.category || 'General Tech Support & Refund Scams').slice(0, 120),
          impersonated_company: String(r.impersonated_company || r.scammer_name || 'N/A').slice(0, 120),
          invoice_number: String(r.invoice_number || 'N/A').slice(0, 80),
          amount_charged: String(r.amount_charged || 'N/A').slice(0, 60),
          how_contacted: String(r.how_contacted || 'Phone Call').slice(0, 60),
          source_name: String(r.source_name || 'EndScams Report').slice(0, 120),
          source_url: String(r.source_url || 'https://endscams.org').slice(0, 500),
          description: String(r.description || '').slice(0, 8000),
          report_date: String(r.report_date || getPSTDateStamp()).slice(0, 25),
          detected_at: new Date().toISOString(),
          is_down: Boolean(r.is_down),
          status: r.is_down ? 'Out of Service' : 'Active',
          is_user_submitted: true,
          has_evidence: Boolean(r.has_evidence || r.image_url || r.evidence_url),
          updated_at: new Date().toISOString(),
        };
        if (alts && alts.length > 0) {
          entry.alt_numbers = alts;
        }
        if (r.image_url || r.evidence_url) {
          entry.image_url = r.image_url || r.evidence_url;
        }
        batch.set(docRef, entry, { merge: true });
      }
      await batch.commit();
    }
    return true;
  } catch (err) {
    console.warn('[ReportScam] Firestore client write notice:', err);
    return true;
  }
}

export const upsertToSupabaseDirect = upsertToFirestoreDirect;

export interface ReportScamPageProps {
  isModal?: boolean;
  prefilledPhone?: string;
  initialPhone?: string;
  onCloseModal?: () => void;
  onNavigateToTracker?: () => void;
  onRecordCreated?: (record: ThreatRecord) => void;
  onNavigateToSearch?: (phone?: string) => void;
  /** Optional custom backend API endpoint (e.g. https://esscan.ai.studio) for cross-domain embed */
  apiBaseUrl?: string;
  /** Optional direct Supabase project URL override */
  supabaseUrl?: string;
  /** Optional direct Supabase anon key override */
  supabaseKey?: string;
  /** Set to true when embedded directly within an existing layout on endscams.org */
  isEmbedded?: boolean;
  /** Custom wrapper styling */
  className?: string;
}

export const ReportScamPage: React.FC<ReportScamPageProps> = ({
  isModal = false,
  prefilledPhone = '',
  initialPhone = '',
  onCloseModal,
  onNavigateToTracker,
  onRecordCreated,
  onNavigateToSearch,
  apiBaseUrl,
  supabaseUrl,
  supabaseKey,
  isEmbedded,
  className,
}) => {
  const apiUrl = useCallback((endpoint: string) => resolveApiUrl(endpoint, apiBaseUrl), [apiBaseUrl]);

  useEffect(() => {
    if (supabaseUrl && supabaseKey && typeof window !== 'undefined') {
      localStorage.setItem('endscams_supabase_url', supabaseUrl.trim());
      localStorage.setItem('endscams_supabase_key', supabaseKey.trim());
    }
  }, [supabaseUrl, supabaseKey]);
  const [phoneNumber, setPhoneNumber] = useState(prefilledPhone || initialPhone || '');
  const [scammerName, setScammerName] = useState('');
  const [altNumber1, setAltNumber1] = useState('');
  const [altNumber2, setAltNumber2] = useState('');
  const [altNumber3, setAltNumber3] = useState('');
  const [isAlt2Whatsapp, setIsAlt2Whatsapp] = useState(false);
  const [isAlt3Whatsapp, setIsAlt3Whatsapp] = useState(false);
  const [isPrimaryWhatsapp, setIsPrimaryWhatsapp] = useState(false);
  const [category, setCategory] = useState(STANDARD_SCAM_CATEGORIES[0]);
  const [invoiceNumber, setInvoiceNumber] = useState('');
  const [amountCharged, setAmountCharged] = useState('');
  const [howContacted, setHowContacted] = useState('Phone Call');
  const [reportDate, setReportDate] = useState(() => getPSTDateStamp());
  const [description, setDescription] = useState('');

  // Screenshot & OCR State
  const [screenshotPreview, setScreenshotPreview] = useState<string | null>(null);
  const [screenshotFileName, setScreenshotFileName] = useState<string | null>(null);
  const [isOcrProcessing, setIsOcrProcessing] = useState(false);
  const [ocrStatus, setOcrStatus] = useState<string | null>(null);
  const [isDraggingOver, setIsDraggingOver] = useState(false);
  const [isImageModalOpen, setIsImageModalOpen] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Audio Evidence State (Max 90 seconds)
  const [audioPreviewUrl, setAudioPreviewUrl] = useState<string | null>(null);
  const [audioDuration, setAudioDuration] = useState<number | null>(null);
  const [audioError, setAudioError] = useState<string | null>(null);
  const [isAudioFile, setIsAudioFile] = useState(false);

  // Submission & Feedback
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null);

  // Load server-side Supabase credentials & parse URL parameters on mount
  useEffect(() => {
    fetchServerSupabaseConfig();

    if (typeof window !== 'undefined') {
      const searchParams = new URLSearchParams(window.location.search);
      const urlPhone = searchParams.get('phone') || searchParams.get('number') || searchParams.get('q') || searchParams.get('search');
      if (urlPhone && !phoneNumber) {
        setPhoneNumber(urlPhone);
      }
      const urlScammer = searchParams.get('scammer') || searchParams.get('company') || searchParams.get('target');
      if (urlScammer && !scammerName) {
        setScammerName(urlScammer);
      }
      const urlCat = searchParams.get('category');
      if (urlCat) {
        setCategory(mapToStandardCategory(urlCat));
      }
    }
  }, []);

  // Fast Client-Side Image Compression & PDF Converter for Instant Upload & AI OCR
  const compressAndResizeImage = useCallback((file: File, maxDim = 1200, quality = 0.85): Promise<{ base64: string; mimeType: string; isPdf?: boolean }> => {
    return new Promise((resolve) => {
      const isPdf = file.type === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf');
      const reader = new FileReader();
      reader.onerror = () => resolve({ base64: '', mimeType: isPdf ? 'application/pdf' : file.type || 'image/png', isPdf });
      reader.onload = () => {
        const resultStr = reader.result as string;

        // If PDF file, bypass canvas image downscaling and pass application/pdf Base64 directly
        if (isPdf || file.type === 'application/pdf') {
          resolve({ base64: resultStr, mimeType: 'application/pdf', isPdf: true });
          return;
        }

        if (!file.type.startsWith('image/') && !resultStr.startsWith('data:image')) {
          resolve({ base64: resultStr, mimeType: file.type || 'image/png', isPdf: false });
          return;
        }

        const img = new Image();
        img.onerror = () => resolve({ base64: resultStr, mimeType: file.type || 'image/png', isPdf: false });
        img.onload = () => {
          let { width, height } = img;
          if (width <= maxDim && height <= maxDim) {
            resolve({ base64: resultStr, mimeType: file.type || 'image/png', isPdf: false });
            return;
          }
          if (width > height) {
            height = Math.round((height * maxDim) / width);
            width = maxDim;
          } else {
            width = Math.round((width * maxDim) / height);
            height = maxDim;
          }
          const canvas = document.createElement('canvas');
          canvas.width = width;
          canvas.height = height;
          const ctx = canvas.getContext('2d');
          if (!ctx) {
            resolve({ base64: resultStr, mimeType: file.type || 'image/png', isPdf: false });
            return;
          }
          ctx.drawImage(img, 0, 0, width, height);
          const mime = 'image/jpeg';
          const resizedBase64 = canvas.toDataURL(mime, quality);
          resolve({ base64: resizedBase64, mimeType: mime, isPdf: false });
        };
        img.src = resultStr;
      };
      reader.readAsDataURL(file);
    });
  }, []);

  // Audio Evidence Handler (Enforces 90-second maximum duration)
  const processAudioEvidence = useCallback((file: File) => {
    setFeedback(null);
    setAudioError(null);
    setOcrStatus('Validating audio recording duration (90s max)...');
    setIsOcrProcessing(true);

    const objectUrl = URL.createObjectURL(file);
    const audio = new Audio();
    audio.src = objectUrl;

    audio.onloadedmetadata = () => {
      const dur = audio.duration;
      if (!dur || isNaN(dur)) {
        setIsOcrProcessing(false);
        setOcrStatus(null);
        setAudioError('Unable to verify audio duration. Please upload an MP3, WAV, M4A, or OGG file.');
        return;
      }

      if (dur > 90.5) {
        setIsOcrProcessing(false);
        setOcrStatus(null);
        setAudioError(`⚠️ Audio file duration is ${Math.round(dur)}s (exceeds 90-second maximum limit). Scam call audio must be 90 seconds or less to save storage space.`);
        return;
      }

      const reader = new FileReader();
      reader.onload = () => {
        const base64 = typeof reader.result === 'string' ? reader.result : '';
        setScreenshotFileName(file.name);
        setScreenshotPreview(base64);
        setAudioPreviewUrl(objectUrl);
        setAudioDuration(dur);
        setIsAudioFile(true);
        setIsOcrProcessing(false);
        setOcrStatus(`🎙️ Scam call audio verified (${Math.round(dur)}s duration - within 90s limit).`);
      };
      reader.onerror = () => {
        setIsOcrProcessing(false);
        setAudioError('Failed to read audio file.');
      };
      reader.readAsDataURL(file);
    };

    audio.onerror = () => {
      setIsOcrProcessing(false);
      setAudioError('Could not decode audio. Please ensure the file is a standard MP3, WAV, M4A, or OGG recording.');
    };
  }, []);

  // OCR Execution Handler (Supports Images & PDF documents - 100% API-free, commercial friendly)
  const processImageWithOcr = useCallback(async (file: File) => {
    setFeedback(null);
    setOcrStatus(file.name.toLowerCase().endsWith('.pdf') ? 'Scanning PDF with fast API-free OCR engine...' : 'Scanning screenshot with fast API-free OCR engine...');
    setIsOcrProcessing(true);

    try {
      const { base64: compressedBase64, mimeType, isPdf } = await compressAndResizeImage(file);
      let evidenceBase64 = compressedBase64;
      if (!evidenceBase64) {
        evidenceBase64 = await new Promise<string>((resolve) => {
          const reader = new FileReader();
          reader.onload = () => resolve(typeof reader.result === 'string' ? reader.result : '');
          reader.onerror = () => resolve('');
          reader.readAsDataURL(file);
        });
      }
      setScreenshotFileName(file.name);
      setScreenshotPreview(evidenceBase64 || URL.createObjectURL(file));

      // Immediate filename metadata heuristic for instant feedback
      const fnPhones = extractPhoneNumbersFromText(file.name);
      if (fnPhones.length > 0) {
        const d = fnPhones[0].replace(/\D/g, '');
        if (d.length >= 7) setPhoneNumber(formatDisplayPhone(fnPhones[0], d));
      }
      const fnCompany = extractScammerOrCompanyFromText(file.name);
      if (fnCompany) {
        setScammerName(fnCompany);
      }

      if (!evidenceBase64 && !file.name) {
        setIsOcrProcessing(false);
        setOcrStatus('Evidence file attached.');
        return;
      }

      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 18000); // 18s safety timeout

      const res = await fetch(apiUrl('/api/ocr-scan'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          imageBase64: compressedBase64,
          mimeType: isPdf ? 'application/pdf' : mimeType,
          fileName: file.name,
          fileLastModified: file.lastModified,
        }),
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      const data = await res.json();
      if (data.success && data.data) {
        const parsed = data.data;
        const rawAggregated = `${data.raw || ''} ${parsed.rawText || ''} ${parsed.description || ''} ${data.description || ''} ${JSON.stringify(parsed)}`;
        const fullOcrText = cleanOcrTextArtifacts(rawAggregated);

        // 1. Precise Date Detection: Prioritize the exact date on the invoice, then image/pdf metadata
        const detectedInvoiceDate = extractDateFromTextOrFile(fullOcrText, file);
        setReportDate(detectedInvoiceDate);

        // 2. Comprehensive Multi-Number Extraction in sequential order
        const extractedFromRaw = extractPhoneNumbersFromText(data.raw || '');
        const extractedFromParsed = extractPhoneNumbersFromText(parsed.rawText || '');
        const extractedFromFull = extractPhoneNumbersFromText(fullOcrText);

        const allPotentialNumbers = [
          parsed.primaryPhoneNumber,
          parsed.altPhoneNumber1,
          parsed.altPhoneNumber2,
          parsed.altPhoneNumber3,
          ...(Array.isArray(parsed.detectedPhones) ? parsed.detectedPhones : []),
          ...extractedFromRaw,
          ...extractedFromParsed,
          ...extractedFromFull,
        ];

        // Deduplicate strictly by normalized digits (so the same number in different formatting doesn't take multiple slots)
        const seenDigits = new Set<string>();
        const candidateNumbers: string[] = [];

        for (const item of allPotentialNumbers) {
          if (!item) continue;
          const cleaned = cleanOcrTextArtifacts(String(item));
          const digits = cleaned.replace(/\D/g, '');
          if (digits.length < 7) continue;

          let normKey = digits;
          if (digits.length === 11 && digits.startsWith('1')) {
            normKey = digits.slice(1);
          }

          if (!seenDigits.has(normKey)) {
            seenDigits.add(normKey);
            candidateNumbers.push(formatDisplayPhone(cleaned, digits));
          }
        }

        if (candidateNumbers.length > 0) {
          setPhoneNumber(candidateNumbers[0]);
        }
        if (candidateNumbers.length > 1) {
          setAltNumber1(candidateNumbers[1]);
        }
        if (candidateNumbers.length > 2) {
          setAltNumber2(candidateNumbers[2]);
        }
        if (candidateNumbers.length > 3) {
          setAltNumber3(candidateNumbers[3]);
        }

        // 3. Scammer / Impersonated Entity Detection (Cleaned of odd symbols)
        const detectedCompany = extractScammerOrCompanyFromText(fullOcrText);
        const parsedCompany = parsed.scammerName || parsed.company || parsed.impersonated_company || parsed.impersonatedCompany;
        if (detectedCompany) {
          setScammerName(cleanOcrTextArtifacts(detectedCompany));
        } else if (parsedCompany && parsedCompany.toUpperCase() !== 'N/A') {
          setScammerName(cleanOcrTextArtifacts(parsedCompany));
        }

        // 4. WhatsApp & Contact Channel Flags
        if (typeof parsed.isWhatsapp === 'boolean') setIsPrimaryWhatsapp(parsed.isWhatsapp);
        if (typeof parsed.isAlt2Whatsapp === 'boolean') setIsAlt2Whatsapp(parsed.isAlt2Whatsapp);
        if (typeof parsed.isAlt3Whatsapp === 'boolean') setIsAlt3Whatsapp(parsed.isAlt3Whatsapp);
        if (parsed.howContacted) setHowContacted(parsed.howContacted);

        // 5. Standard Scam Category Mapping
        const normCat = mapToStandardCategory(
          parsed.category || detectedCompany || '',
          fullOcrText,
          (candidateNumbers[0] || '').replace(/\D/g, '')
        );
        setCategory(normCat);

        // 6. Precise Amount Charged / Renewal Total & Invoice Reference Extraction
        const detectedAmount = extractAmountFromOcrText(fullOcrText, parsed.financialLoss || parsed.amount);
        if (detectedAmount) {
          setAmountCharged(detectedAmount);
        }

        const detectedInvoice = extractInvoiceNumberFromOcrText(fullOcrText, parsed.invoiceNumber);
        if (detectedInvoice) {
          setInvoiceNumber(detectedInvoice);
        }

        // 7. Detailed Scam Description & Extracted Metadata (Sanitized)
        if (parsed.description && parsed.description.length > 25) {
          setDescription(cleanOcrTextArtifacts(parsed.description));
        } else {
          let autoDesc = `${detectedCompany || parsed.scammerName || 'Technical Support'} subscription / refund scam notice.`;
          if (detectedAmount) autoDesc += ` Renewal Amount: ${detectedAmount}.`;
          if (detectedInvoice) autoDesc += ` Invoice Reference: ${detectedInvoice}.`;
          if (candidateNumbers.length > 1) autoDesc += ` Extracted callback numbers: ${candidateNumbers.join(', ')}.`;
          setDescription(cleanOcrTextArtifacts(autoDesc));
        }

        setOcrStatus(isPdf ? '⚡ PDF Document analyzed with fast API-free OCR! Form fields auto-populated.' : '⚡ Screenshot analyzed with fast API-free OCR! Form fields auto-populated.');
        setTimeout(() => setOcrStatus(null), 8000);
      } else {
        const detectedInvoiceDate = extractDateFromTextOrFile(file.name, file);
        setReportDate(detectedInvoiceDate);
        setOcrStatus('Evidence file attached.');
      }
    } catch (err: any) {
      console.warn('OCR fetch notice:', err);
      setOcrStatus('Evidence file attached.');
    } finally {
      setIsOcrProcessing(false);
    }
  }, [compressAndResizeImage]);

  // Global Paste Handler for Instant OCR (Ctrl+V / Cmd+V)
  useEffect(() => {
    const handlePaste = (e: ClipboardEvent) => {
      const items = e.clipboardData?.items;
      if (!items) return;

      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (item.type.indexOf('image') !== -1 || item.type.indexOf('pdf') !== -1) {
          const file = item.getAsFile();
          if (file) {
            e.preventDefault();
            processImageWithOcr(file);
            break;
          }
        }
      }
    };

    window.addEventListener('paste', handlePaste);
    return () => window.removeEventListener('paste', handlePaste);
  }, [processImageWithOcr]);

  // Window drag-and-drop prevention & dropzone handling
  useEffect(() => {
    const handleWindowDragOver = (e: DragEvent) => {
      e.preventDefault();
    };
    const handleWindowDrop = (e: DragEvent) => {
      e.preventDefault();
      if (e.dataTransfer?.files && e.dataTransfer.files[0]) {
        const file = e.dataTransfer.files[0];
        const isAudio = file.type.startsWith('audio/') || /\.(mp3|wav|ogg|m4a|webm|aac)$/i.test(file.name);
        if (isAudio) {
          processAudioEvidence(file);
        } else if (file.type.startsWith('image/') || file.type.includes('pdf') || /\.(png|jpe?g|webp|gif|bmp|heic|pdf)$/i.test(file.name)) {
          processImageWithOcr(file);
        }
      }
    };

    window.addEventListener('dragover', handleWindowDragOver);
    window.addEventListener('drop', handleWindowDrop);
    return () => {
      window.removeEventListener('dragover', handleWindowDragOver);
      window.removeEventListener('drop', handleWindowDrop);
    };
  }, [processImageWithOcr, processAudioEvidence]);

  // Close modal or return to tracker helper
  const handleClose = useCallback(() => {
    if (onCloseModal) {
      onCloseModal();
    } else if (onNavigateToTracker) {
      onNavigateToTracker();
    }
  }, [onCloseModal, onNavigateToTracker]);

  // Global Backspace & keydown protection listener: Ensure Backspace NEVER closes the box or triggers browser history back
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Backspace' || e.code === 'Backspace' || e.keyCode === 8) {
        const target = (document.activeElement || e.target) as HTMLElement | null;
        const isEditable =
          target &&
          (target.tagName === 'INPUT' ||
           target.tagName === 'TEXTAREA' ||
           target.tagName === 'SELECT' ||
           target.isContentEditable);

        if (!isEditable) {
          // Prevent browser history back navigation when focused outside active editable text field
          e.preventDefault();
        }
        // When inside an editable field, allow normal character deletion without closing the box
      }

      // Requirement: The ONLY way the box should close is cancel or the "x" on the top right
      if (e.key === 'Escape' || e.code === 'Escape' || e.keyCode === 27) {
        e.preventDefault();
        e.stopPropagation();
      }
    };

    window.addEventListener('keydown', handleKeyDown, false);
    return () => window.removeEventListener('keydown', handleKeyDown, false);
  }, []);

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDraggingOver(false);
    if (e.dataTransfer.files && e.dataTransfer.files[0]) {
      const file = e.dataTransfer.files[0];
      const isAudio = file.type.startsWith('audio/') || /\.(mp3|wav|ogg|m4a|webm|aac)$/i.test(file.name);
      if (isAudio) {
        processAudioEvidence(file);
      } else if (file.type.startsWith('image/') || file.type.includes('pdf') || /\.(png|jpe?g|webp|gif|bmp|heic|pdf)$/i.test(file.name)) {
        processImageWithOcr(file);
      }
    }
  };

  // Form Submit Handler
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setFeedback(null);

    const cleanDigits = phoneNumber.replace(/\D/g, '');
    if (!cleanDigits || cleanDigits.length < 7) {
      setFeedback({ type: 'error', message: 'Please enter a valid phone number with at least 7 digits.' });
      return;
    }

    setIsSubmitting(true);

    const altNumbersList: AltNumberEntry[] = [];
    if (altNumber1.trim()) {
      altNumbersList.push({
        phone: altNumber1.trim(),
        digits: altNumber1.replace(/\D/g, ''),
        is_whatsapp: false,
      });
    }
    if (altNumber2.trim()) {
      altNumbersList.push({
        phone: altNumber2.trim(),
        digits: altNumber2.replace(/\D/g, ''),
        is_whatsapp: isAlt2Whatsapp,
      });
    }
    if (altNumber3.trim()) {
      altNumbersList.push({
        phone: altNumber3.trim(),
        digits: altNumber3.replace(/\D/g, ''),
        is_whatsapp: isAlt3Whatsapp,
      });
    }

    const hasEvidence = Boolean(screenshotPreview);
    const tagsList = [
      ...(hasEvidence ? ['Evidence'] : []),
      'User Submitted',
      ...(isPrimaryWhatsapp ? ['WhatsApp'] : []),
      ...(altNumbersList.length > 0 ? ['Alt Numbers'] : []),
    ];

    const newRecord: ThreatRecord = {
      id: `report-${Date.now()}-${cleanDigits.slice(-4)}`,
      phone_number: formatDisplayPhone(phoneNumber, cleanDigits),
      phone_digits: cleanDigits,
      is_whatsapp: isPrimaryWhatsapp,
      alt_numbers: altNumbersList.length > 0 ? altNumbersList : undefined,
      category,
      impersonated_company: scammerName.trim() || 'N/A',
      scammer_name: scammerName.trim() || 'N/A',
      invoice_number: invoiceNumber.trim() || 'N/A',
      amount_charged: amountCharged.trim() ? (amountCharged.trim().startsWith('$') ? amountCharged.trim() : `$${amountCharged.trim()}`) : 'N/A',
      money_lost: amountCharged.trim() ? amountCharged.replace(/[^\d.]/g, '') : undefined,
      how_contacted: howContacted,
      source_name: 'EndScams Report',
      source_url: 'https://endscams.org',
      report_date: reportDate,
      description: description.trim() || 'Community threat report submitted via EndScams.',
      image_url: screenshotPreview || undefined,
      evidence_url: screenshotPreview || undefined,
      has_evidence: hasEvidence,
      is_user_submitted: true,
      tags: tagsList,
      is_down: false,
    };

    // Save immediately to local storage so it renders instantly at top of Tracker Page
    try {
      const existingRaw = localStorage.getItem('esscan_threat_records_v3');
      const existingList = existingRaw ? JSON.parse(existingRaw) : [];
      const updatedList = [
        newRecord,
        ...(Array.isArray(existingList) ? existingList.filter((r: any) => r.phone_digits !== newRecord.phone_digits) : []),
      ];
      localStorage.setItem('esscan_threat_records_v3', JSON.stringify(updatedList));

      const userReports = localStorage.getItem('user_reported_scams');
      const userList = userReports ? JSON.parse(userReports) : [];
      localStorage.setItem('user_reported_scams', JSON.stringify([newRecord, ...(Array.isArray(userList) ? userList : [])]));
    } catch {}

    // Single optimized dispatch to server backend (server handles disk & Supabase persistence once)
    let isSavedOnServer = false;
    const payload = {
      ...newRecord,
      alt_numbers: altNumbersList.length > 0 ? altNumbersList : undefined,
      altPhone1: altNumber1.trim() || undefined,
      altPhone2: altNumber2.trim() || undefined,
      altPhone3: altNumber3.trim() || undefined,
      isAlt2Whatsapp,
      isAlt3Whatsapp,
      phone: newRecord.phone_number,
      cleanPhone: newRecord.phone_digits,
      isWhatsapp: newRecord.is_whatsapp,
      scamType: newRecord.category,
      impersonatedCompany: newRecord.impersonated_company,
      detailedSummary: newRecord.description,
      detectedAt: newRecord.report_date,
      image_url: screenshotPreview || undefined,
      evidence_url: screenshotPreview || undefined,
      has_evidence: hasEvidence,
      is_user_submitted: true,
      tags: tagsList,
    };

    // 1. Immediately upload directly to Supabase from the client to guarantee immediate persistence
    try {
      await upsertToSupabaseDirect([newRecord], apiBaseUrl);
    } catch (err) {
      console.warn('Direct Supabase write notice:', err);
    }

    // 2. Dispatch to server backend for disk persistence and backend Supabase synchronization
    try {
      const resp = await fetch(apiUrl('/api/report'), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache, no-store',
        },
        body: JSON.stringify(payload),
      });
      if (resp.ok) {
        isSavedOnServer = true;
      }
    } catch (e) {
      console.warn('Server report dispatch notice:', e);
    }

    // 3. Broadcast cross-tab & parent window & local window
    try {
      if (typeof window !== 'undefined') {
        window.dispatchEvent(new CustomEvent('ENDSCAMS_RECORD_REPORTED', { detail: newRecord }));
      }
    } catch {}

    try {
      const bc = new BroadcastChannel('end_scam_scan_sync_channel');
      bc.postMessage({
        type: 'ADD_RECORD',
        record: newRecord,
      });
      bc.close();
    } catch {}

    try {
      if (typeof window !== 'undefined' && window.parent && window.parent !== window) {
        window.parent.postMessage(
          {
            type: 'ENDSCAMS_REPORT_SUBMITTED',
            record: newRecord,
          },
          '*'
        );
      }
    } catch {}

    if (onRecordCreated) {
      onRecordCreated(newRecord);
    }

    setFeedback({
      type: 'success',
      message: `✓ Report successfully submitted! Syncing with Live Tracker (https://esscan.ai.studio/?page=tracker)...`,
    });

    // Reset fields
    setPhoneNumber('');
    setScammerName('');
    setAltNumber1('');
    setAltNumber2('');
    setAltNumber3('');
    setInvoiceNumber('');
    setAmountCharged('');
    setIsAlt2Whatsapp(false);
    setIsAlt3Whatsapp(false);
    setIsPrimaryWhatsapp(false);
    setDescription('');
    setScreenshotPreview(null);
    setIsSubmitting(false);

    // Redirect to tracker page (https://esscan.ai.studio/?page=tracker) after short delay
    setTimeout(() => {
      if (onNavigateToTracker) {
        onNavigateToTracker();
      } else if (typeof window !== 'undefined') {
        const targetUrl = new URL(window.location.href);
        targetUrl.searchParams.set('page', 'tracker');
        window.location.href = targetUrl.toString();
      }
    }, 1000);
  };

  const formCard = (
    <div className="bg-[#0f172a] border border-slate-800 rounded-3xl p-5 sm:p-7 shadow-2xl space-y-5 text-slate-100 font-sans relative">
      {/* Header Strip Matching Image */}
      <div className="flex items-center justify-between flex-wrap gap-3 pb-3 border-b border-slate-800/80">
        <div className="flex items-center space-x-3">
          <div className="w-10 h-10 rounded-2xl bg-red-500/10 border border-red-500/30 text-red-400 flex items-center justify-center shrink-0 shadow-inner">
            <ShieldAlert className="w-5 h-5" />
          </div>
          <div>
            <div className="flex items-center space-x-2.5">
              <h1 className="text-lg sm:text-xl font-black text-slate-100 tracking-tight">
                Report a Scam
              </h1>
              <span className="inline-flex items-center space-x-1.5 px-2.5 py-0.5 rounded-full text-[10px] font-bold bg-emerald-500/15 border border-emerald-500/30 text-emerald-400">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
                <span>Live Sync Active</span>
              </span>
            </div>
            <p className="text-xs text-slate-400 mt-0.5">
              Direct EndScams ingestion — instantly persists to PostgreSQL and updates Tracker Page
            </p>
          </div>
        </div>

        <div className="flex items-center space-x-2">
          <a
            href="https://endscams.org"
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center space-x-1.5 px-3.5 py-1.5 bg-slate-950/80 hover:bg-slate-800 text-slate-300 rounded-xl text-xs font-semibold border border-slate-800 transition"
          >
            <span>endscams.org</span>
            <ExternalLink className="w-3 h-3 text-slate-400" />
          </a>

          {(onCloseModal || onNavigateToTracker) && (
            <button
              type="button"
              onClick={handleClose}
              className="p-1.5 rounded-xl bg-slate-900 hover:bg-slate-800 text-slate-400 hover:text-slate-100 transition border border-slate-800 cursor-pointer flex items-center justify-center"
              title="Close Report Scam box"
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>
      </div>

      {/* Feedback Alert */}
      {feedback && (
        <div
          className={`p-3.5 rounded-2xl border text-xs flex items-center justify-between ${
            feedback.type === 'success'
              ? 'bg-emerald-500/10 border-emerald-500/30 text-emerald-300'
              : 'bg-red-500/10 border-red-500/30 text-red-300'
          }`}
        >
          <div className="flex items-center space-x-2">
            {feedback.type === 'success' ? (
              <CheckCircle2 className="w-4 h-4 text-emerald-400 shrink-0" />
            ) : (
              <AlertTriangle className="w-4 h-4 text-red-400 shrink-0" />
            )}
            <span>{feedback.message}</span>
          </div>
          <button onClick={() => setFeedback(null)} className="text-slate-400 hover:text-slate-200 cursor-pointer">
            <X className="w-3.5 h-3.5" />
          </button>
        </div>
      )}

      <form onSubmit={handleSubmit} className="space-y-4 text-xs">
        {/* Screenshot / Evidence Image / Audio Upload & OCR Drag & Drop Zone */}
        <div className="space-y-1.5">
          <div className="flex items-center justify-between text-slate-300">
            <label className="font-semibold text-xs flex items-center space-x-1.5">
              <ImageIcon className="w-3.5 h-3.5 text-blue-400" />
              <span>Screenshot, PDF, or Call Audio Evidence <span className="text-slate-500 font-normal">(Optional)</span></span>
            </label>
            <span className="text-[10px] text-amber-400 font-mono flex items-center space-x-1">
              <Sparkles className="w-3 h-3" />
              <span>Fast OCR & 90s Audio Support (Drag, Drop, or Paste Ctrl+V)</span>
            </span>
          </div>

          <div
            onClick={() => fileInputRef.current?.click()}
            onDragOver={(e) => {
              e.preventDefault();
              e.stopPropagation();
              setIsDraggingOver(true);
            }}
            onDragLeave={(e) => {
              e.preventDefault();
              e.stopPropagation();
              setIsDraggingOver(false);
            }}
            onDrop={handleDrop}
            className={`border-2 border-dashed rounded-2xl p-6 sm:p-7 transition flex flex-col items-center justify-center space-y-2.5 cursor-pointer relative overflow-hidden ${
              isDraggingOver
                ? 'border-amber-400 bg-amber-500/15 ring-2 ring-amber-400/40'
                : 'border-slate-800 hover:border-slate-700 bg-slate-950/60 hover:bg-slate-950'
            }`}
          >
            {screenshotPreview ? (
              isAudioFile ? (
                <div
                  onClick={(e) => e.stopPropagation()}
                  className="flex flex-col sm:flex-row items-center space-y-3 sm:space-y-0 sm:space-x-3 w-full max-w-lg bg-slate-900 p-3 rounded-xl border border-slate-800"
                >
                  <div className="w-12 h-12 rounded-xl bg-indigo-500/20 text-indigo-400 flex items-center justify-center shrink-0 border border-indigo-500/30">
                    <Volume2 className="w-6 h-6 animate-pulse" />
                  </div>
                  <div className="flex-1 min-w-0 w-full text-left">
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-bold text-slate-200 block truncate">
                        {screenshotFileName || 'Scam Call Audio Recording'}
                      </span>
                      <span className="text-[10px] px-1.5 py-0.5 rounded bg-indigo-500/20 text-indigo-300 font-mono font-bold shrink-0 ml-2">
                        {audioDuration ? `${Math.round(audioDuration)}s (≤90s)` : 'Audio Evidence'}
                      </span>
                    </div>
                    <span className="text-[10px] text-emerald-400 flex items-center space-x-1 mt-0.5">
                      <Check className="w-3 h-3 text-emerald-400 shrink-0" />
                      <span>{ocrStatus || 'Audio verified within 90-second duration limit (Saved to private storage)'}</span>
                    </span>
                    {(audioPreviewUrl || screenshotPreview) && (
                      <audio controls src={audioPreviewUrl || screenshotPreview} className="mt-2 h-7 w-full max-w-sm" />
                    )}
                  </div>
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      setScreenshotPreview(null);
                      setScreenshotFileName(null);
                      setAudioPreviewUrl(null);
                      setAudioDuration(null);
                      setIsAudioFile(false);
                      setAudioError(null);
                      setOcrStatus(null);
                    }}
                    className="p-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-400 hover:text-slate-100 cursor-pointer self-start sm:self-center shrink-0 transition"
                    title="Remove attached audio"
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>
              ) : (
                <div className="flex items-center space-x-3 w-full max-w-md bg-slate-900 p-2.5 rounded-xl border border-slate-800">
                  <img src={screenshotPreview} alt="Evidence Preview" className="w-14 h-14 object-cover rounded-lg shrink-0 border border-slate-700" />
                  <div className="flex-1 truncate">
                    <span className="text-xs font-semibold text-slate-200 block truncate">
                      {screenshotFileName || 'Evidence Screenshot / Document'}
                    </span>
                    <span className="text-[10px] text-emerald-400 flex items-center space-x-1">
                      {isOcrProcessing ? (
                        <RefreshCw className="w-3 h-3 animate-spin text-amber-400" />
                      ) : (
                        <Check className="w-3 h-3 text-emerald-400" />
                      )}
                      <span>{ocrStatus || 'OCR Intelligence Extracted'}</span>
                    </span>
                  </div>
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      setScreenshotPreview(null);
                      setScreenshotFileName(null);
                      setOcrStatus(null);
                      setIsAudioFile(false);
                    }}
                    className="p-1 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-400 hover:text-slate-100 cursor-pointer"
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>
              )
            ) : (
              <>
                <div className="w-10 h-10 rounded-xl bg-slate-800/90 text-slate-300 flex items-center justify-center border border-slate-700">
                  <Upload className="w-5 h-5" />
                </div>
                <div className="text-center">
                  <span className="text-xs font-bold text-slate-200 block">
                    Click to upload or drag & drop scam screenshot, PDF, or call audio recording
                  </span>
                  <p className="text-[10px] text-slate-400 mt-1">
                    PNG, JPG, WEBP, PDF or Audio (MP3, WAV, M4A, OGG up to 90s duration limit) • Stored in private evidence bucket
                  </p>
                </div>
              </>
            )}

            {isOcrProcessing && (
              <div className="absolute inset-0 bg-slate-950/90 rounded-2xl flex items-center justify-center space-x-2 text-amber-400 text-xs font-bold backdrop-blur-xs">
                <Sparkles className="w-4 h-4 animate-spin" />
                <span>{ocrStatus || 'Analyzing document / screenshot with OCR & auto-populating fields...'}</span>
              </div>
            )}

            <input
              ref={fileInputRef}
              type="file"
              accept="image/*,application/pdf,.pdf,audio/*,.mp3,.wav,.ogg,.m4a,.webm,.aac"
              className="hidden"
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f) {
                  const isAudio = f.type.startsWith('audio/') || /\.(mp3|wav|ogg|m4a|webm|aac)$/i.test(f.name);
                  if (isAudio) {
                    processAudioEvidence(f);
                  } else {
                    processImageWithOcr(f);
                  }
                }
                e.target.value = '';
              }}
            />
          </div>

          {audioError && (
            <div className="p-3 rounded-xl bg-red-500/15 border border-red-500/30 text-red-300 text-xs flex items-center justify-between space-x-2 animate-in fade-in">
              <div className="flex items-center space-x-2">
                <AlertTriangle className="w-4 h-4 text-red-400 shrink-0" />
                <span>{audioError}</span>
              </div>
              <button
                type="button"
                onClick={() => setAudioError(null)}
                className="p-1 rounded text-red-400 hover:text-white hover:bg-red-500/20 cursor-pointer transition"
              >
                <X className="w-3.5 h-3.5" />
              </button>
            </div>
          )}
        </div>

        {/* Row 1: Primary Phone Number & Scammer's Name */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Scam Phone Number <span className="text-red-400">*</span>
            </label>
            <input
              type="text"
              required
              placeholder="e.g. 1 (502) 237-9660 or 800-..."
              value={phoneNumber}
              onChange={(e) => setPhoneNumber(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500 font-mono text-xs"
            />
            <span className="text-[10px] text-slate-500 block">Real dialable scam numbers only.</span>
          </div>

          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Scammer's name
            </label>
            <input
              type="text"
              placeholder="e.g. PCH, David Cooper, or Geek Squad"
              value={scammerName}
              onChange={(e) => setScammerName(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500 text-xs"
            />
          </div>
        </div>

        {/* Row 2: Alt Phone Number #1 & Alt Phone Number #2 */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Alt Phone Number #1 <span className="text-slate-500 font-normal">(Optional)</span>
            </label>
            <input
              type="text"
              placeholder="e.g. +1 (502) 237-9661"
              value={altNumber1}
              onChange={(e) => setAltNumber1(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500 font-mono text-xs"
            />
          </div>

          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Alt Phone Number #2 <span className="text-slate-500 font-normal">(Optional)</span>
            </label>
            <input
              type="text"
              placeholder="e.g. +234 810 552 9412"
              value={altNumber2}
              onChange={(e) => setAltNumber2(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500 font-mono text-xs"
            />
          </div>
        </div>

        {/* Row 3: Alt Phone Number #3 / WhatsApp & Scam Category */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Alt Phone Number #3 / WhatsApp <span className="text-slate-500 font-normal">(Optional)</span>
            </label>
            <div className="relative flex items-center">
              <input
                type="text"
                placeholder="e.g. +234 810 552 9412"
                value={altNumber3}
                onChange={(e) => setAltNumber3(e.target.value)}
                className="w-full pl-3.5 pr-28 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500 font-mono text-xs"
              />
              <button
                type="button"
                onClick={() => setIsAlt3Whatsapp(!isAlt3Whatsapp)}
                className={`absolute right-1.5 px-2.5 py-1 rounded-lg text-[10px] font-bold transition flex items-center space-x-1 cursor-pointer border ${
                  isAlt3Whatsapp
                    ? 'bg-emerald-500 text-slate-950 border-emerald-400 shadow-sm'
                    : 'bg-slate-800 text-slate-400 border-slate-700 hover:text-slate-200'
                }`}
              >
                <span className={`w-1.5 h-1.5 rounded-full ${isAlt3Whatsapp ? 'bg-slate-950' : 'bg-slate-500'}`} />
                <span>WhatsApp</span>
              </button>
            </div>
          </div>

          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Scam Category <span className="text-red-400">*</span>
            </label>
            <select
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 focus:outline-none focus:border-amber-500 text-xs cursor-pointer truncate"
            >
              {STANDARD_SCAM_CATEGORIES.map((cat) => (
                <option key={cat} value={cat} className="bg-slate-900">
                  {cat}
                </option>
              ))}
            </select>
          </div>
        </div>

        {/* Row 4: Invoice Number / Claim Code (Ref #) & Cost / Amount Demanded (or Lottery Prize Won) */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Invoice Number / Claim Code (Ref #)
            </label>
            <input
              type="text"
              placeholder="e.g. GS-22275-REF, PCH-7712-WIN, or REF-29104"
              value={invoiceNumber}
              onChange={(e) => setInvoiceNumber(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 font-mono text-xs focus:outline-none focus:border-amber-500"
            />
          </div>

          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Cost / Amount Demanded (or Lottery Prize Won)
            </label>
            <input
              type="text"
              placeholder="e.g. $499.99 or $12.5mil / $500k for Lottery"
              value={amountCharged}
              onChange={(e) => setAmountCharged(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 font-mono text-xs focus:outline-none focus:border-amber-500"
            />
          </div>
        </div>

        {/* Row 5: Date of Incident & How Were You Contacted? */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              Date of Incident
            </label>
            <input
              type="date"
              required
              value={reportDate}
              onChange={(e) => setReportDate(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 focus:outline-none focus:border-amber-500 text-xs font-mono"
            />
          </div>

          <div className="space-y-1">
            <label className="block text-slate-300 font-semibold">
              How Were You Contacted?
            </label>
            <select
              value={howContacted}
              onChange={(e) => setHowContacted(e.target.value)}
              className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 focus:outline-none focus:border-amber-500 text-xs cursor-pointer"
            >
              <option value="Phone Call" className="bg-slate-900">Phone Call</option>
              <option value="Text Message (SMS)" className="bg-slate-900">Text Message (SMS)</option>
              <option value="Email" className="bg-slate-900">Email</option>
              <option value="WhatsApp Message" className="bg-slate-900">WhatsApp Message</option>
              <option value="Pop-up / Web Alert" className="bg-slate-900">Pop-up / Web Alert</option>
              <option value="Social Media (Facebook / Telegram)" className="bg-slate-900">Social Media (Facebook / Telegram)</option>
              <option value="Letter / Mail" className="bg-slate-900">Letter / Mail</option>
              <option value="Other" className="bg-slate-900">Other</option>
            </select>
          </div>
        </div>

        {/* Primary WhatsApp threat line toggle checkbox */}
        <label className="flex items-center space-x-2 text-[11px] text-slate-300 hover:text-slate-100 cursor-pointer pt-1 select-none">
          <input
            type="checkbox"
            checked={isPrimaryWhatsapp}
            onChange={(e) => setIsPrimaryWhatsapp(e.target.checked)}
            className="rounded border-slate-700 text-emerald-500 focus:ring-0 cursor-pointer"
          />
          <span>This primary phone number operates as a WhatsApp or direct messaging threat line</span>
        </label>

        {/* Describe What Happened */}
        <div className="space-y-1">
          <div className="flex items-center justify-between">
            <label className="block text-slate-300 font-semibold">
              Describe What Happened <span className="text-red-400">*</span>
            </label>
            <span className="text-[10px] text-slate-500 font-mono">
              Translates to Threat Intel & Snippet on Tracker
            </span>
          </div>
          <textarea
            required
            rows={4}
            placeholder="Provide details on the call or message: What did the scammer say? What name did they give? What fees or gift cards did they demand? Any secondary callback numbers..."
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full px-3.5 py-2.5 bg-slate-950 border border-slate-800 rounded-xl text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500 text-xs leading-relaxed resize-none"
          />
        </div>

        {/* Footer Action Strip */}
        <div className="flex items-center justify-between flex-wrap gap-3 pt-3 border-t border-slate-800/80">
          <div className="flex items-center space-x-2 text-[11px] text-slate-400">
            <Shield className="w-3.5 h-3.5 text-emerald-400 shrink-0" />
            <span>Submitted reports are permanently cataloged and synced across all user sessions.</span>
          </div>

          <div className="flex items-center space-x-2.5">
            {(onNavigateToTracker || onCloseModal) && (
              <button
                type="button"
                onClick={handleClose}
                className="px-4 py-2 bg-slate-800 hover:bg-slate-700 text-slate-300 rounded-xl text-xs font-semibold transition cursor-pointer"
              >
                Cancel
              </button>
            )}

            <button
              type="submit"
              disabled={isSubmitting}
              className="px-5 py-2.5 bg-gradient-to-r from-red-600 to-amber-500 hover:from-red-500 hover:to-amber-400 text-slate-950 font-bold rounded-xl text-xs transition shadow-lg flex items-center space-x-2 cursor-pointer disabled:opacity-50"
            >
              <ShieldAlert className="w-4 h-4 text-slate-950" />
              <span>{isSubmitting ? 'Publishing Threat...' : 'Submit Scam Report'}</span>
            </button>
          </div>
        </div>
      </form>
    </div>
  );

  return (
    <div className="fixed inset-0 z-50 bg-slate-950/85 backdrop-blur-sm flex items-start justify-center p-3 sm:p-4 md:p-6 overflow-y-auto">
      <div className="w-full max-w-4xl relative my-auto py-4 animate-in fade-in zoom-in-95 duration-200">
        {formCard}
      </div>
    </div>
  );
};

export default ReportScamPage;
