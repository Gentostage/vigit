export const metadata = {
  title: "Vigit — Git changes, inside Neovim",
  description:
    "A keyboard-first Neovim workspace for reviewing, editing, staging, and unstaging Git changes.",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
