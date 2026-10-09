// Reproducible SQL handoff for Supabase SQL Editor; never connects to a database.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
const files=['202609040000_business_date_ambiguity.sql','202609040001_split_weighing_intake.sql'];
const parts=[];
for(const file of files){
  const source=await readFile(new URL('../supabase/migrations/'+file,import.meta.url),'utf8');
  parts.push('-- '+file+'\n'+source.replace(/^begin;\r?$/m,'').replace(/^commit;\r?$/m,''));
}
const verify=`select case when
  to_regprocedure('public.allocate_weighing_intake(uuid,text,bigint,bigint,bigint,bigint,text,uuid)') is not null
  and to_regprocedure('public.list_unallocated_weighing_batches(integer)') is not null
  and exists (select 1 from pg_class where oid='public.intake_allocations'::regclass and relrowsecurity and relforcerowsecurity)
  then 'SPLIT_READY' else 'CHECK_REQUIRED' end as result;
`;
const text='-- Mi Mi Khine: run ONCE in project usufheovofmqchjlzlsz SQL Editor.\n-- No business records are inserted or deleted. Both upgrades are atomic.\n-- If already installed, do not rerun; use the final SELECT verification only.\nbegin;\n'+parts.join('\n')+'\ncommit;\n'+verify;
const output=new URL('../outputs/split-intake-upgrade.sql',import.meta.url);
await mkdir(new URL('../outputs/',import.meta.url),{recursive:true});
await writeFile(output,text,'utf8');
console.log('Prepared outputs/split-intake-upgrade.sql');
