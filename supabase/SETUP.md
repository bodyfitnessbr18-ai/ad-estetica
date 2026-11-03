# Configuração inicial do Supabase — AD Estética Automotiva

O schema inicial está em `supabase/migrations/001_initial_schema.sql`.

## 1. Criar as tabelas e funções
1. Abra o projeto Supabase `ayxgfmzwdkqeidqurbpz`.
2. Entre em **SQL Editor** → **New query**.
3. Abra o arquivo `supabase/migrations/001_initial_schema.sql` neste repositório, copie todo o conteúdo e execute no SQL Editor.

## 2. Convidar o administrador
1. No Supabase, abra **Authentication** → **Users**.
2. Escolha **Add user** → **Send invite**.
3. Informe `jonassilva2006@gmail.com` e envie o convite.
4. O administrador deverá aceitar o convite e definir a senha pelo fluxo do Supabase.

## 3. Conceder acesso administrativo
Depois de o usuário aparecer em Authentication → Users, execute no SQL Editor:

```sql
insert into public.admin_users (user_id, email)
select id, email
from auth.users
where lower(email) = lower('jonassilva2006@gmail.com')
on conflict (user_id)
do update set email = excluded.email;
```

Confirme que foi cadastrado:

```sql
select a.user_id, a.email
from public.admin_users a;
```

## Segurança
- Use no frontend somente a URL do projeto e a chave **Publishable** (ou a antiga **anon**).
- Nunca coloque `service_role`, secret key ou senha do banco no HTML, GitHub ou navegador.
- As políticas RLS restringem leitura dos dados pessoais dos agendamentos a usuários autenticados que estejam em `admin_users`.
- A função `create_booking` faz a validação de conflito no banco; o frontend não deve ser a única proteção contra reservas simultâneas.

## Estado
Esta etapa prepara o banco e a autorização do administrador. A integração do frontend e os testes de ponta a ponta ainda precisam ser concluídos antes de publicar a branch.
