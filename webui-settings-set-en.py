#!/usr/bin/env python3
import psycopg2
import json
import argparse
import os
import sys
import fnmatch
from datetime import datetime

# Connection parameters strictly from ENV
DB_CONFIG = {
    'host': os.getenv('OW_DB_HOST', 'localhost'),
    'port': int(os.getenv('OW_DB_PORT', 5432)),
    'database': os.getenv('OW_DB_NAME', 'openwebui'),
    'user': os.getenv('OW_DB_USER', 'openwebui'),
    'password': os.getenv('OW_DB_PASSWORD', 'openwebui')  # Password
}

DONOR_EMAIL = 'user@host.com' # from what kind user we take settings

def log(msg, level='info'):
    prefix = {'info': 'ℹ️', 'warn': '⚠️', 'error': '❌', 'success': '✅', 'prompt': '🔹', 'diff': '📊'}
    print(f"{prefix.get(level, '•')} {msg}")

def ask_user(prompt, default=False):
    suffix = "[Y/n]" if default else "[y/N]"
    try:
        resp = input(f"{prompt} {suffix}: ").strip().lower()
        if not resp:
            return default
        return resp in ('y', 'yes')
    except (EOFError, KeyboardInterrupt):
        print("\n🚫 Interrupted by user")
        sys.exit(0)

def check_environment():
    """Check dependencies and environment variables"""
    errors = []
    if not DB_CONFIG['password']:
        errors.append("OW_DB_PASSWORD is not set")
    for key in ['host', 'database', 'user']:
        if not DB_CONFIG[key]:
            errors.append(f"OW_DB_{key.upper()} is not set")
    
    if errors:
        log("❌ Configuration errors:", 'error')
        for e in errors:
            print(f"   • {e}")
        sys.exit(1)
    
    try:
        import psycopg2
    except ImportError:
        log("❌ psycopg2 is not installed. Run: pip install psycopg2-binary", 'error')
        sys.exit(1)

def matches_filter(email, include_patterns, exclude_patterns):
    """Check email against glob patterns"""
    if include_patterns:
        if not any(fnmatch.fnmatch(email, p) for p in include_patterns):
            return False
    if exclude_patterns:
        if any(fnmatch.fnmatch(email, p) for p in exclude_patterns):
            return False
    return True

def create_backup(cur, users, backup_path):
    """Create JSON backup of users"""
    backup_data = {
        'created_at': datetime.now().isoformat(),
        'users': []
    }
    for user_id, email, settings in users:
        backup_data['users'].append({
            'id': user_id,
            'email': email,
            'settings': settings
        })
    
    dir_name = os.path.dirname(backup_path)
    if dir_name:
        os.makedirs(dir_name, exist_ok=True)
        
    with open(backup_path, 'w', encoding='utf-8') as f:
        json.dump(backup_data, f, indent=2, ensure_ascii=False)
    log(f"💾 Backup saved: {backup_path}", 'success')

def migrate_settings(args):
    conn = None
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        cur = conn.cursor()

        # Check connection
        try:
            cur.execute('SELECT 1')
        except Exception as e:
            log(f"❌ Database connection error: {e}", 'error')
            sys.exit(1)

        # Get donor
        cur.execute('SELECT id, settings FROM "user" WHERE email = %s', (DONOR_EMAIL,))
        donor = cur.fetchone()
        if not donor:
            raise Exception(f"User {DONOR_EMAIL} not found")
        
        donor_id, donor_settings = donor
        donor_json = json.loads(donor_settings) if isinstance(donor_settings, str) else donor_settings
        log(f"✓ Donor found: ID={donor_id}")

        # Collect candidates
        candidates = {}
        ui_data = donor_json.get('ui', {})

        if 'audio' in ui_data:
            candidates['ui.audio'] = {'path': ['ui', 'audio'], 'value': ui_data['audio']}

        pinned = ui_data.get('pinnedModels') or donor_json.get('pinned_models')
        if pinned:
            candidates['pinned_models'] = {
                'path': ['pinned_models'], 
                'value': pinned, 
                'ui_key': 'pinnedModels'
            }

        if 'directConnections' in ui_data:
            candidates['ui.directConnections'] = {
                'path': ['ui', 'directConnections'], 
                'value': ui_data['directConnections'],
                'danger': True
            }

        for key, value in ui_data.items():
            if key in ('audio', 'directConnections', 'pinnedModels'):
                continue
            candidates[f'ui.{key}'] = {'path': ['ui', key], 'value': value}

        # Select parameters
        selected_keys = []

        if args.interactive:
            log("🎛️ INTERACTIVE MODE", 'info')
            print("-" * 60)
            for key, info in candidates.items():
                danger_mark = " ⚠️ API-KEYS!" if info.get('danger') else ""
                if ask_user(f"Copy {key}{danger_mark}?", default=False):
                    selected_keys.append(key)
            print("-" * 60)
            
            if not selected_keys:
                log("Nothing selected, exiting.", 'warn')
                return
        else:
            if args.copy_all_ui:
                selected_keys.extend([k for k in candidates if not k.startswith('ui.directConnections')])
            if args.copy_pinned_models and 'pinned_models' in candidates:
                selected_keys.append('pinned_models')
            if args.copy_direct_connections and 'ui.directConnections' in candidates:
                if args.yes or ask_user("⚠️ Copy directConnections?", default=False):
                    selected_keys.append('ui.directConnections')

        if not selected_keys:
            log("No parameters selected for copying.", 'warn')
            return

        log(f"📦 Selected: {', '.join(selected_keys)}")

        # Get users with filtering
        cur.execute('SELECT id, email, settings FROM "user" WHERE email != %s', (DONOR_EMAIL,))
        all_users = cur.fetchall()

        include_patterns = args.include_emails.split(',') if args.include_emails else []
        exclude_patterns = args.exclude_emails.split(',') if args.exclude_emails else []

        users = [u for u in all_users if matches_filter(u[1], include_patterns, exclude_patterns)]
        filtered_out = len(all_users) - len(users)

        if filtered_out > 0:
            log(f"🔍 Filtered out users: {filtered_out}", 'info')

        if not users:
            log("No users to update after filtering.", 'warn')
            return

        # Diff mode
        if args.diff:
            log("📊 DIFF MODE", 'info')
            print("-" * 60)
            diff_count = 0
            for user_id, email, user_settings in users:
                user_json = json.loads(user_settings) if isinstance(user_settings, str) else (user_settings or {})
                diffs = []
                for key in selected_keys:
                    info = candidates[key]
                    target = user_json
                    for p in info['path'][:-1]:
                        target = target.get(p, {})
                    current_val = target.get(info['path'][-1])
                    if current_val != info['value']:
                        diffs.append(key)
                if diffs:
                    log(f"📊 {email}: differs in {', '.join(diffs)}", 'diff')
                    diff_count += 1
                elif args.verbose:
                    log(f"  ✓ {email}: no changes")
            print("-" * 60)
            log(f"Total: {diff_count} users have differences", 'info')
            return

        # Backup
        if args.backup:
            backup_path = args.backup
            if '{date}' in backup_path:
                backup_path = backup_path.replace('{date}', datetime.now().strftime('%Y%m%d_%H%M%S'))
            create_backup(cur, users, backup_path)

        # Apply
        if args.dry_run:
            log(f"🔍 DRY-RUN: {len(users)} users would be updated", 'warn')
        else:
            updated = 0
            for user_id, email, user_settings in users:
                user_json = json.loads(user_settings) if isinstance(user_settings, str) else (user_settings or {})
                
                for key in selected_keys:
                    info = candidates[key]
                    target = user_json
                    path = info['path']
                    for p in path[:-1]:
                        target = target.setdefault(p, {})
                    target[path[-1]] = info['value']
                    
                    if key == 'pinned_models' and 'ui_key' in info:
                        user_json.setdefault('ui', {})[info['ui_key']] = info['value']

                cur.execute("""
                    UPDATE "user" SET settings = %s::jsonb, updated_at = EXTRACT(EPOCH FROM NOW()) * 1000
                    WHERE id = %s
                """, (json.dumps(user_json), user_id))
                updated += 1
                
                if args.verbose or updated <= 5 or updated % 10 == 0:
                    log(f"  ✓ {email}")
            
            conn.commit()
            log(f"✅ Done! Updated: {updated}", 'success')

    except Exception as e:
        if conn:
            conn.rollback()
            log("🔄 Transaction rolled back", 'warn')
        log(f"❌ Error: {e}", 'error')
        raise
    finally:
        if conn:
            conn.close()

if __name__ == '__main__':
    # Check environment at startup
    check_environment()

    parser = argparse.ArgumentParser(
        description='🔄 OpenWebUI Settings Migrator',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s -i                       # Interactive parameter selection
  %(prog)s -a -p                    # All UI + pinned_models
  %(prog)s --diff                   # Show differences without changes
  %(prog)s -i --backup backup.json  # Interactive with backup
  %(prog)s -a --include "admin@*"   # Only admins
  %(prog)s --dry-run -v             # Test run with verbose log
        '''
    )
    parser.add_argument('-i', '--interactive', action='store_true', help='Interactive parameter selection')
    parser.add_argument('-p', '--copy-pinned-models', action='store_true', help='Copy pinned_models')
    parser.add_argument('-d', '--copy-direct-connections', action='store_true', help='Copy directConnections')
    parser.add_argument('-a', '--copy-all-ui', action='store_true', help='Copy all UI settings')
    parser.add_argument('--dry-run', action='store_true', help='Test mode (no changes)')
    parser.add_argument('-y', '--yes', action='store_true', help='Skip confirmations')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose logging')
    parser.add_argument('--diff', action='store_true', help='Diff mode (compare only)')
    parser.add_argument('--backup', metavar='PATH', help='Create backup before writing (supports {date})')
    parser.add_argument('--include-emails', metavar='PATTERNS', help='Email patterns to include (comma-separated)')
    parser.add_argument('--exclude-emails', metavar='PATTERNS', help='Email patterns to exclude (comma-separated)')
    
    args = parser.parse_args()

    if len(sys.argv) == 1:
        parser.print_help()
        sys.exit(0)

    print("\n" + "="*60)
    print("🔄 WebUI Settings Migrator")
    print(f"📧 Donor: {DONOR_EMAIL}")
    print(f"🎛️ Mode: {'Interactive' if args.interactive else 'Automatic'}")
    if args.diff:
        print("📊 Diff: enabled")
    if args.backup:
        print(f"💾 Backup: {args.backup}")
    print("="*60 + "\n")

    migrate_settings(args)
  
