# Configuração inicial do Supabase — AD Estética Automotiva

O schema inicial está em `supabase/migrations/001_initial_schema.sql`.

## Situação desta etapa
- A duração dos serviços é armazenada em minutos (`duration_minutes`), permitindo valores como 45, 90 ou 135 minutos.
- O cadastro de expediente é feito por dia da semana, de segunda a sábado.
- Bloqueios possuem horário inicial e final.
- A função `create_booking` valida expediente, duração, bloqueios e sobreposição com outros agendamentos.
- A integração completa do frontend ainda não está concluída. O site não deve ser considerado conectado ao banco até que os testes de leitura, gravação, login e agendamento sejam realizados.

## 1. Confirmar a integração GitHub
No painel do Supabase, abra **Project Settings → Integrations → GitHub** e confirme:
- Repositório: `bodyfitnessbr18-ai/ad-estetica`
- Diretório de trabalho: `.`
- Branch de produção: `main`

Não altere a branch de produção nesta etapa. A implementação está sendo preparada em `feature/supabase-database`.

## 2. Aplicar o schema
**Não execute o SQL ainda.** Primeiro confirme a integração GitHub e conclua a revisão do frontend. Isso evita aplicar uma estrutura incompleta ou executar a mesma migração duas vezes.

Quando a etapa estiver aprovada, a migração deverá ser aplicada uma única vez no projeto correto, seguindo o fluxo de migrações configurado no Supabase.

## 3. Convidar o administrador
Depois que a estrutura estiver aplicada:
1. No Supabase, abra **Authentication → Users**.
2. Escolha **Add user → Send invite**.
3. Informe o e-mail administrativo definido para o projeto.
4. O administrador deverá aceitar o convite e definir a senha pelo fluxo do Supabase.

## 4. Conceder acesso administrativo
Depois que o usuário aparecer em Authentication → Users, associe seu UUID à tabela `admin_users`:

```sql
insert into public.admin_users (user_id, email)
select id, email
from auth.users
where lower(email) = lower('jonassilva2006@gmail.com')
on conflict (user_id)
do update set email = excluded.email;
```

Confirme o cadastro:

```sql
select a.user_id, a.email
from public.admin_users a;
```

## Segurança
- No frontend, use somente a URL do projeto e a chave **Publishable** (ou a antiga **anon**).
- Nunca coloque `service_role`, secret key ou senha do banco no HTML, GitHub ou navegador.
- As políticas RLS restringem dados pessoais dos agendamentos a administradores autenticados.
- A criação pública de reservas ocorre pela função `create_booking`, que valida os conflitos no banco.

## Antes de publicar
A integração do frontend, o preenchimento dos horários de funcionamento, a configuração do usuário administrador e os testes ponta a ponta ainda precisam ser concluídos. Não mescle esta branch em `main` até validar tudo.
