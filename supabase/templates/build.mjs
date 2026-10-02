// Builds the Supabase Auth email templates in the app's look.
// Run: node supabase/templates/build.mjs   (writes confirmation.html and magic_link.html next to this file)
// Paste each file into Supabase → Authentication → Emails → the matching template, for dev and prod.
// The app signs people up with user metadata {name, lang}; the emails greet by name and switch to Spanish for lang "es"
// and to Portuguese for lang "pt".
import { writeFileSync } from 'node:fs';

const F = "Nunito,'Segoe UI',Helvetica,Arial,sans-serif";
const ink = '#22303f', mut = '#7b8a99', acc = '#2f8fa3', accs = '#e2f2f5';
// Go template: $es / $pt are true when the person used the app in Spanish / Portuguese; missing lang falls back to English
// the app icon, served by the deployed site (email clients don't show inline SVG)
const LOGO = 'https://fq-organization.github.io/ShiftSwaap/icons/icon-192.png';
const head = '{{ $es := false }}{{ $pt := false }}{{ with .Data.lang }}{{ if eq . "es" }}{{ $es = true }}{{ end }}{{ if eq . "pt" }}{{ $pt = true }}{{ end }}{{ end }}';
const t = (en, es, pt) => `{{ if $es }}${es}{{ else if $pt }}${pt}{{ else }}${en}{{ end }}`;
// short name ("Francisco G.") saved at sign-up, falling back to the full name; never wraps
const name = '{{ with .Data.short }} <span style="white-space:nowrap">{{ . }}</span>{{ else }}{{ with .Data.name }} <span style="white-space:nowrap">{{ . }}</span>{{ end }}{{ end }}';

function email({ title, intro, button, foot }) {
  return `${head}<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><meta name="supported-color-schemes" content="light">
<title>Swapecito</title>
<link href="https://fonts.googleapis.com/css2?family=Nunito:wght@600;700;800&display=swap" rel="stylesheet"></head>
<body style="margin:0;padding:0;background:#eef6fa">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#eef6fa;background-image:linear-gradient(#e2f0f8,#f6f9fc 320px)">
<tr><td align="center" style="padding:40px 16px">
 <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:480px">
  <tr><td align="center" style="padding-bottom:22px">
   <img src="${LOGO}" width="64" height="64" alt="Swapecito" style="display:block;width:64px;height:64px;border:0;border-radius:20px">
   <div style="font:800 24px/1.2 ${F};color:${ink};margin-top:12px;letter-spacing:-.01em">Swapecito</div>
   <div style="font:600 14px/1.4 ${F};color:${mut};margin-top:2px">${t('Swap shifts without the chaos.', 'Cambia turnos sin el caos.', 'Troca turnos sem o caos.')}</div>
  </td></tr>
  <tr><td style="background:#ffffff;border-radius:24px;padding:34px 30px 30px;box-shadow:0 8px 28px rgba(40,70,100,.08)">
   <h1 style="margin:0 0 10px;font:800 22px/1.3 ${F};color:${ink}">${title}</h1>
   <p style="margin:0 0 26px;font:600 15px/1.6 ${F};color:${mut}">${intro}</p>
   <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" style="border-radius:99px;background:${acc};box-shadow:0 6px 16px rgba(47,143,163,.3)">
    <a href="{{ .ConfirmationURL }}" style="display:inline-block;padding:15px 34px;font:800 16px/1 ${F};color:#ffffff;text-decoration:none;border-radius:99px">${button}</a>
   </td></tr></table>
   <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:28px"><tr>
    <td style="background:${accs};border-radius:16px;padding:14px 16px;font:700 13px/1.5 ${F};color:#237a8c">
     &#128197; ${t('Your calendar', 'Tu calendario', 'O teu calendário')} &nbsp;·&nbsp; &#8644; ${t('Swaps that follow the rules', 'Cambios que cumplen las reglas', 'Trocas que cumprem as regras')} &nbsp;·&nbsp; &#128172; ${t('Group feed', 'Muro del grupo', 'Mural do grupo')}
    </td></tr></table>
   <p style="margin:24px 0 0;font:600 12px/1.6 ${F};color:${mut}">${t("If the button doesn't work, copy this link into your browser:", 'Si el botón no funciona, copia este enlace en tu navegador:', 'Se o botão não funcionar, copia este link para o navegador:')}<br>
    <a href="{{ .ConfirmationURL }}" style="color:#237a8c;word-break:break-all">{{ .ConfirmationURL }}</a></p>
  </td></tr>
  <tr><td align="center" style="padding:22px 20px 0;font:600 12px/1.6 ${F};color:${mut}">${foot}</td></tr>
 </table>
</td></tr></table>
</body></html>
`;
}

const files = {
  'confirmation.html': email({
    title: t(`Welcome${name}! &#128075;`, `¡Te damos la bienvenida${name}! &#128075;`, `Bem-vindo${name}! &#128075;`),
    intro: t('Confirm your email to finish creating your Swapecito account. Then create a room or join one with an invite link.',
             'Confirma tu correo para terminar de crear tu cuenta de Swapecito. Después crea una sala o únete a una con un enlace de invitación.',
             'Confirma o teu e-mail para terminares de criar a tua conta Swapecito. Depois cria uma sala ou entra numa com um link de convite.'),
    button: t('Confirm my email', 'Confirmar mi correo', 'Confirmar o meu e-mail'),
    foot: t('You got this email because {{ .Email }} was used to sign up for Swapecito. If that wasn\'t you, you can ignore it.',
            'Recibes este correo porque se usó {{ .Email }} para crear una cuenta en Swapecito. Si no fuiste tú, puedes ignorarlo.',
            'Recebeste este e-mail porque {{ .Email }} foi usado para criar uma conta no Swapecito. Se não foste tu, podes ignorá-lo.'),
  }),
  'magic_link.html': email({
    title: t(`Your sign-in link${name}`, `Tu enlace para entrar${name}`, `O teu link para entrar${name}`),
    intro: t('Tap the button to sign in to Swapecito. The link works once and expires soon.',
             'Toca el botón para entrar en Swapecito. El enlace funciona una sola vez y caduca pronto.',
             'Toca no botão para entrares no Swapecito. O link funciona uma única vez e expira em breve.'),
    button: t('Sign in to Swapecito', 'Entrar en Swapecito', 'Entrar no Swapecito'),
    foot: t("Someone asked to sign in to Swapecito as {{ .Email }}. If that wasn't you, you can ignore this email.",
            'Alguien pidió entrar en Swapecito como {{ .Email }}. Si no fuiste tú, puedes ignorar este correo.',
            'Alguém pediu para entrar no Swapecito como {{ .Email }}. Se não foste tu, podes ignorar este e-mail.'),
  }),
  'recovery.html': email({
    title: t(`Reset your password${name}`, `Restablece tu contraseña${name}`, `Repõe a tua palavra-passe${name}`),
    intro: t('Tap the button to choose a new password for your Swapecito account. The link works once and expires in 1 hour.',
             'Toca el botón para elegir una contraseña nueva para tu cuenta de Swapecito. El enlace funciona una sola vez y caduca en 1 hora.',
             'Toca no botão para escolheres uma nova palavra-passe para a tua conta Swapecito. O link funciona uma única vez e expira em 1 hora.'),
    button: t('Choose a new password', 'Elegir contraseña nueva', 'Escolher nova palavra-passe'),
    foot: t("Someone asked to reset the password for {{ .Email }}. If that wasn't you, ignore this email: your password stays the same.",
            'Alguien pidió restablecer la contraseña de {{ .Email }}. Si no fuiste tú, ignora este correo: tu contraseña no cambia.',
            'Alguém pediu para repor a palavra-passe de {{ .Email }}. Se não foste tu, ignora este e-mail: a tua palavra-passe não muda.'),
  }),
};
const dir = new URL('.', import.meta.url);
for (const [f, html] of Object.entries(files)) writeFileSync(new URL(f, dir), html);
console.log('wrote', Object.keys(files).join(', '));
