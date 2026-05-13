-- ══════════════════════════════════════════════════════
-- Urban3DQuest — Migration : ajout authentification joueur
-- Coller dans : Supabase Dashboard > SQL Editor > Run
-- (à exécuter UNE SEULE FOIS sur une base existante)
-- ══════════════════════════════════════════════════════

-- Ajout des colonnes d'authentification sur la table players
alter table players
  add column if not exists password_hash text default '',
  add column if not exists session_token text;

-- Les joueurs existants auront password_hash = '' (chaîne vide).
-- Au premier login après la mise à jour, ils pourront choisir un mot de passe
-- qui sera automatiquement associé à leur compte (first-login claim).
