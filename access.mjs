// Unknown or missing roles fail closed. Reading is still constrained by Supabase RLS.
export const canWriteOperations = profile => profile?.role === 'admin';
export function requireOperationsWrite(profile) {
  if (!canWriteOperations(profile)) throw new Error('Tu cuenta de chofer es de solo lectura. Contacta a administración para realizar cambios.');
}
