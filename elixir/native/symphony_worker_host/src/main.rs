#![cfg_attr(not(windows), allow(dead_code, unused_imports))]

#[cfg(not(windows))]
fn main() {
    eprintln!("symphony-worker-host is supported only on Windows");
    std::process::exit(2);
}

#[cfg(windows)]
mod windows {
    use std::env;
    use std::ffi::c_void;
    use std::fs;
    use std::mem::{size_of, zeroed};
    use std::path::Path;
    use std::thread;
    use std::time::{Duration, Instant};

    type Handle = isize;
    type Bool = i32;
    type Dword = u32;

    const INVALID_HANDLE_VALUE: Handle = -1;
    const CREATE_SUSPENDED: Dword = 0x0000_0004;
    const STARTF_USESTDHANDLES: Dword = 0x0000_0100;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: Dword = 0x0000_2000;
    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: Dword = 9;
    const JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION: Dword = 1;
    const SYNCHRONIZE: Dword = 0x0010_0000;
    const PROCESS_QUERY_LIMITED_INFORMATION: Dword = 0x1000;
    const JOB_OBJECT_TERMINATE: Dword = 0x0008;
    const JOB_OBJECT_QUERY: Dword = 0x0004;
    const ERROR_INVALID_PARAMETER: Dword = 87;
    const ERROR_NOT_FOUND: Dword = 1168;
    const INFINITE: Dword = 0xffff_ffff;
    const INVALID_FILE_ATTRIBUTES: Dword = 0xffff_ffff;
    const FILE_ATTRIBUTE_REPARSE_POINT: Dword = 0x0000_0400;
    const STD_INPUT_HANDLE: Dword = -10_i32 as Dword;
    const STD_OUTPUT_HANDLE: Dword = -11_i32 as Dword;
    const STD_ERROR_HANDLE: Dword = -12_i32 as Dword;

    #[repr(C)]
    struct StartupInfoW {
        cb: Dword,
        lp_reserved: *mut u16,
        lp_desktop: *mut u16,
        lp_title: *mut u16,
        dw_x: Dword,
        dw_y: Dword,
        dw_x_size: Dword,
        dw_y_size: Dword,
        dw_x_count_chars: Dword,
        dw_y_count_chars: Dword,
        dw_fill_attribute: Dword,
        dw_flags: Dword,
        w_show_window: u16,
        cb_reserved2: u16,
        lp_reserved2: *mut u8,
        h_std_input: Handle,
        h_std_output: Handle,
        h_std_error: Handle,
    }

    #[repr(C)]
    struct ProcessInformation {
        h_process: Handle,
        h_thread: Handle,
        dw_process_id: Dword,
        dw_thread_id: Dword,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct LargeInteger {
        quad_part: i64,
    }

    #[repr(C)]
    struct JobObjectBasicLimitInformation {
        per_process_user_time_limit: LargeInteger,
        per_job_user_time_limit: LargeInteger,
        limit_flags: Dword,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: Dword,
        affinity: usize,
        priority_class: Dword,
        scheduling_class: Dword,
    }

    #[repr(C)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    struct JobObjectExtendedLimitInformation {
        basic_limit_information: JobObjectBasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    #[repr(C)]
    struct JobObjectBasicAccountingInformation {
        total_user_time: LargeInteger,
        total_kernel_time: LargeInteger,
        this_period_total_user_time: LargeInteger,
        this_period_total_kernel_time: LargeInteger,
        total_page_fault_count: Dword,
        total_processes: Dword,
        active_processes: Dword,
        total_terminated_processes: Dword,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct FileTime {
        low_date_time: Dword,
        high_date_time: Dword,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> Handle;
        fn OpenJobObjectW(access: Dword, inherit: Bool, name: *const u16) -> Handle;
        fn SetInformationJobObject(job: Handle, class: Dword, info: *const c_void, length: Dword) -> Bool;
        fn QueryInformationJobObject(
            job: Handle,
            class: Dword,
            info: *mut c_void,
            length: Dword,
            return_length: *mut Dword,
        ) -> Bool;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> Bool;
        fn IsProcessInJob(process: Handle, job: Handle, result: *mut Bool) -> Bool;
        fn TerminateJobObject(job: Handle, exit_code: Dword) -> Bool;
        fn CreateProcessW(
            application_name: *const u16,
            command_line: *mut u16,
            process_attributes: *const c_void,
            thread_attributes: *const c_void,
            inherit_handles: Bool,
            creation_flags: Dword,
            environment: *const c_void,
            current_directory: *const u16,
            startup_info: *mut StartupInfoW,
            process_information: *mut ProcessInformation,
        ) -> Bool;
        fn ResumeThread(thread: Handle) -> Dword;
        fn WaitForSingleObject(handle: Handle, milliseconds: Dword) -> Dword;
        fn OpenProcess(access: Dword, inherit: Bool, process_id: Dword) -> Handle;
        fn GetProcessTimes(
            process: Handle,
            creation: *mut FileTime,
            exit: *mut FileTime,
            kernel: *mut FileTime,
            user: *mut FileTime,
        ) -> Bool;
        fn GetExitCodeProcess(process: Handle, exit_code: *mut Dword) -> Bool;
        fn GetStdHandle(handle: Dword) -> Handle;
        fn GetFileAttributesW(path: *const u16) -> Dword;
        fn CloseHandle(handle: Handle) -> Bool;
        fn GetLastError() -> Dword;
    }

    pub fn run() -> Result<(), String> {
        let args: Vec<String> = env::args().skip(1).collect();

        if args.first().map(String::as_str) == Some("--stop") {
            return stop_recorded(&args[1..]);
        }
        if args.first().map(String::as_str) == Some("--is-reparse") {
            return is_reparse(&args[1..]);
        }

        launch(&args)
    }

    fn launch(args: &[String]) -> Result<(), String> {
        let separator = args.iter().position(|argument| argument == "--").ok_or("missing -- command separator")?;
        let options = &args[..separator];
        let command = &args[separator + 1..];
        if command.is_empty() {
            return Err("worker command is required".into());
        }

        let parent_pid = option(options, "--parent-pid").ok_or("--parent-pid is required")?
            .parse::<Dword>().map_err(|_| "invalid --parent-pid")?;
        let job_name = option(options, "--job-name").ok_or("--job-name is required")?;
        let identity_file = option(options, "--identity-file").ok_or("--identity-file is required")?;
        let cwd = option(options, "--cwd").ok_or("--cwd is required")?;
        let attempt_id = option(options, "--attempt-id").unwrap_or("unmanaged");
        if parent_pid == 0 || job_name.trim().is_empty() || attempt_id.trim().is_empty() {
            return Err("invalid worker ownership identity".into());
        }

        let parent = unsafe { OpenProcess(SYNCHRONIZE, 0, parent_pid) };
        if invalid_handle(parent) {
            return Err(format!("parent process {parent_pid} is unavailable"));
        }

        let job = create_job(job_name)?;
        let child = create_suspended(command, cwd)?;

        if unsafe { AssignProcessToJobObject(job, child.h_process) } == 0 {
            unsafe { CloseHandle(child.h_thread); CloseHandle(child.h_process); CloseHandle(job); CloseHandle(parent); }
            return Err(last_error("AssignProcessToJobObject"));
        }

        if unsafe { ResumeThread(child.h_thread) } == Dword::MAX {
            unsafe { TerminateJobObject(job, 1); CloseHandle(child.h_thread); CloseHandle(child.h_process); CloseHandle(job); CloseHandle(parent); }
            return Err(last_error("ResumeThread"));
        }

        let creation_time = match process_creation_time(child.h_process) {
            Ok(value) => value,
            Err(error) => {
                unsafe { TerminateJobObject(job, 1); CloseHandle(child.h_thread); CloseHandle(child.h_process); CloseHandle(job); CloseHandle(parent); }
                return Err(error);
            }
        };
        if let Err(error) = write_identity(identity_file, job_name, attempt_id, child.dw_process_id, creation_time) {
            // A resumable child without a durable ownership record is not a
            // worker we can safely recover, so end only this verified job.
            unsafe { TerminateJobObject(job, 1); CloseHandle(child.h_thread); CloseHandle(child.h_process); CloseHandle(job); CloseHandle(parent); }
            return Err(error);
        }

        // The helper is the only owner of this Job handle. If BEAM crashes or
        // its port is closed, this monitor or KILL_ON_JOB_CLOSE ends the whole
        // worker tree without touching unrelated processes.
        let monitor_job = job;
        thread::spawn(move || unsafe {
            WaitForSingleObject(parent, INFINITE);
            TerminateJobObject(monitor_job, 1);
        });

        unsafe {
            WaitForSingleObject(child.h_process, INFINITE);
            let mut exit_code = 1;
            if GetExitCodeProcess(child.h_process, &mut exit_code) == 0 {
                CloseHandle(child.h_thread);
                CloseHandle(child.h_process);
                return Err(last_error("GetExitCodeProcess"));
            }
            CloseHandle(child.h_thread);
            CloseHandle(child.h_process);
            // The BEAM port must observe the real child status. Returning Ok
            // here would turn failed hooks and Codex startup failures into
            // false success because the helper process itself exits zero.
            std::process::exit(exit_code as i32);
        }
        // The monitor owns `parent` and `job` until this helper exits. Closing
        // either from this thread would race its blocking wait; process exit
        // closes both handles and KILL_ON_JOB_CLOSE handles the worker tree.
        #[allow(unreachable_code)]
        Ok(())
    }

    fn stop_recorded(options: &[String]) -> Result<(), String> {
        let job_name = option(options, "--job-name").ok_or("--job-name is required")?;
        let pid = option(options, "--pid").ok_or("--pid is required")?
            .parse::<Dword>().map_err(|_| "invalid --pid")?;
        let expected_creation = option(options, "--creation-time").ok_or("--creation-time is required")?
            .parse::<u64>().map_err(|_| "invalid --creation-time")?;

        let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if invalid_handle(process) {
            let error = unsafe { GetLastError() };
            // Only the documented not-found cases may be treated as gone.
            // Access denied and all other failures are unknown ownership.
            if error == ERROR_INVALID_PARAMETER || error == ERROR_NOT_FOUND {
                return Ok(());
            }
            return Err(format!("OpenProcess failed with Win32 error {error}"));
        }
        let actual_creation = match process_creation_time(process) {
            Ok(value) => value,
            Err(error) => {
                unsafe { CloseHandle(process); }
                return Err(error);
            }
        };
        if actual_creation != expected_creation {
            unsafe { CloseHandle(process); }
            return Err("recorded process identity changed; refusing job termination".into());
        }

        let name = wide(job_name);
        let job = unsafe { OpenJobObjectW(JOB_OBJECT_TERMINATE | JOB_OBJECT_QUERY, 0, name.as_ptr()) };
        if invalid_handle(job) {
            unsafe { CloseHandle(process); }
            return Err(last_error("OpenJobObjectW"));
        }
        let mut is_member: Bool = 0;
        if unsafe { IsProcessInJob(process, job, &mut is_member) } == 0 {
            unsafe { CloseHandle(job); CloseHandle(process); }
            return Err(last_error("IsProcessInJob"));
        }
        if is_member == 0 {
            unsafe { CloseHandle(job); CloseHandle(process); }
            return Err("recorded process is not a member of the recorded job".into());
        }
        if unsafe { TerminateJobObject(job, 1) } == 0 {
            let error = last_error("TerminateJobObject");
            unsafe { CloseHandle(job); CloseHandle(process); }
            return Err(error);
        }

        let result = wait_for_job_empty(job, Duration::from_secs(5));
        unsafe { CloseHandle(job); CloseHandle(process); }
        result
    }

    fn wait_for_job_empty(job: Handle, timeout: Duration) -> Result<(), String> {
        let deadline = Instant::now() + timeout;

        loop {
            let mut accounting: JobObjectBasicAccountingInformation = unsafe { zeroed() };
            let mut returned: Dword = 0;
            let queried = unsafe {
                QueryInformationJobObject(
                    job,
                    JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION,
                    &mut accounting as *mut _ as *mut c_void,
                    size_of::<JobObjectBasicAccountingInformation>() as Dword,
                    &mut returned,
                )
            };

            if queried == 0 {
                return Err(last_error("QueryInformationJobObject"));
            }
            if accounting.active_processes == 0 {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "job termination was not confirmed; {} active process(es) remain",
                    accounting.active_processes
                ));
            }

            thread::sleep(Duration::from_millis(25));
        }
    }

    fn is_reparse(options: &[String]) -> Result<(), String> {
        let path = option(options, "--path").ok_or("--path is required")?;
        let path = wide(path);
        let attributes = unsafe { GetFileAttributesW(path.as_ptr()) };
        if attributes == INVALID_FILE_ATTRIBUTES {
            return Err(last_error("GetFileAttributesW"));
        }
        if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            // Keep the exit code deliberately distinct so the Elixir boundary
            // can reject junctions and symlinks without parsing output.
            std::process::exit(3);
        }
        Ok(())
    }

    fn create_job(name: &str) -> Result<Handle, String> {
        let wide_name = wide(name);
        let job = unsafe { CreateJobObjectW(std::ptr::null(), wide_name.as_ptr()) };
        if invalid_handle(job) { return Err(last_error("CreateJobObjectW")); }

        let mut limits: JobObjectExtendedLimitInformation = unsafe { zeroed() };
        limits.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let result = unsafe {
            SetInformationJobObject(
                job,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                &limits as *const _ as *const c_void,
                size_of::<JobObjectExtendedLimitInformation>() as Dword,
            )
        };
        if result == 0 {
            unsafe { CloseHandle(job); }
            Err(last_error("SetInformationJobObject"))
        } else { Ok(job) }
    }

    fn create_suspended(command: &[String], cwd: &str) -> Result<ProcessInformation, String> {
        let mut command_line = wide(&command_line(command));
        let cwd = wide(cwd);
        let mut startup: StartupInfoW = unsafe { zeroed() };
        startup.cb = size_of::<StartupInfoW>() as Dword;
        startup.dw_flags = STARTF_USESTDHANDLES;
        unsafe {
            startup.h_std_input = GetStdHandle(STD_INPUT_HANDLE);
            startup.h_std_output = GetStdHandle(STD_OUTPUT_HANDLE);
            startup.h_std_error = GetStdHandle(STD_ERROR_HANDLE);
        }
        let mut process: ProcessInformation = unsafe { zeroed() };
        let result = unsafe {
            CreateProcessW(
                std::ptr::null(), command_line.as_mut_ptr(), std::ptr::null(), std::ptr::null(), 1,
                CREATE_SUSPENDED, std::ptr::null(), cwd.as_ptr(), &mut startup, &mut process,
            )
        };
        if result == 0 { Err(last_error("CreateProcessW")) } else { Ok(process) }
    }

    fn process_creation_time(process: Handle) -> Result<u64, String> {
        let mut creation: FileTime = unsafe { zeroed() };
        let mut exit: FileTime = unsafe { zeroed() };
        let mut kernel: FileTime = unsafe { zeroed() };
        let mut user: FileTime = unsafe { zeroed() };
        if unsafe { GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user) } == 0 {
            return Err(last_error("GetProcessTimes"));
        }
        Ok(((creation.high_date_time as u64) << 32) | creation.low_date_time as u64)
    }

    fn write_identity(path: &str, job_name: &str, attempt_id: &str, pid: Dword, creation_time: u64) -> Result<(), String> {
        let identity_path = Path::new(path);
        let parent = identity_path.parent().ok_or("identity file has no parent")?;
        fs::create_dir_all(parent).map_err(|error| format!("create identity directory: {error}"))?;
        let payload = format!(
            "{{\"version\":1,\"job_name\":\"{}\",\"attempt_id\":\"{}\",\"child_pid\":{},\"child_creation_time\":{}}}\n",
            json_escape(job_name), json_escape(attempt_id), pid, creation_time
        );
        let temporary = identity_path.with_extension("tmp");
        fs::write(&temporary, payload).map_err(|error| format!("write worker identity: {error}"))?;
        fs::rename(&temporary, identity_path).map_err(|error| format!("persist worker identity: {error}"))
    }

    fn option<'a>(options: &'a [String], name: &str) -> Option<&'a str> {
        options.windows(2).find(|pair| pair[0] == name).map(|pair| pair[1].as_str())
    }

    fn wide(value: &str) -> Vec<u16> { value.encode_utf16().chain(std::iter::once(0)).collect() }
    fn invalid_handle(handle: Handle) -> bool { handle == 0 || handle == INVALID_HANDLE_VALUE }
    fn last_error(operation: &str) -> String { format!("{operation} failed with Win32 error {}", unsafe { GetLastError() }) }

    fn command_line(arguments: &[String]) -> String {
        // cmd.exe gives the text following /c its own parsing rules. Applying
        // C-runtime backslash escaping to that final script changes the quote
        // characters and breaks a .cmd path containing spaces. AppServer owns
        // this exact /d /s /c shape and supplies the already-quoted script.
        if arguments.len() == 5
            && arguments[0].to_ascii_lowercase().ends_with("cmd.exe")
            && arguments[1].eq_ignore_ascii_case("/d")
            && arguments[2].eq_ignore_ascii_case("/s")
            && arguments[3].eq_ignore_ascii_case("/c")
        {
            return format!(
                "{} /d /s /c {}",
                quote_argument(&arguments[0]),
                arguments[4]
            );
        }

        arguments
            .iter()
            .map(|argument| quote_argument(argument))
            .collect::<Vec<_>>()
            .join(" ")
    }
    fn quote_argument(argument: &str) -> String {
        if !argument.is_empty() && !argument.chars().any(|character| character.is_whitespace() || character == '"') { return argument.into(); }
        let mut result = String::from("\"");
        let mut slashes = 0;
        for character in argument.chars() {
            match character {
                '\\' => slashes += 1,
                '"' => { result.push_str(&"\\".repeat(slashes * 2 + 1)); result.push('"'); slashes = 0; }
                _ => { result.push_str(&"\\".repeat(slashes)); result.push(character); slashes = 0; }
            }
        }
        result.push_str(&"\\".repeat(slashes * 2));
        result.push('"'); result
    }
    fn json_escape(value: &str) -> String {
        value.chars().flat_map(|character| match character {
            '"' => "\\\"".chars().collect::<Vec<_>>(), '\\' => "\\\\".chars().collect(), '\n' => "\\n".chars().collect(), '\r' => "\\r".chars().collect(), '\t' => "\\t".chars().collect(), character if character.is_control() => format!("\\u{:04x}", character as u32).chars().collect(), character => vec![character],
        }).collect()
    }

    #[cfg(test)]
    mod tests {
        use super::{command_line, quote_argument};
        #[test]
        fn quotes_windows_arguments_without_command_interpretation() {
            assert_eq!(quote_argument("C:\\work space\\café"), "\"C:\\work space\\café\"");
            assert_eq!(quote_argument("a\\\"b"), "\"a\\\\\\\"b\"");
            assert_eq!(command_line(&["cmd.exe".into(), "/c".into(), "echo safe & literal".into()]), "cmd.exe /c \"echo safe & literal\"");
            assert_eq!(
                command_line(&[
                    "C:\\Windows\\System32\\cmd.exe".into(),
                    "/d".into(),
                    "/s".into(),
                    "/c".into(),
                    "\"\"C:\\Program Files\\Codex\\codex.cmd\" app-server\"".into(),
                ]),
                "C:\\Windows\\System32\\cmd.exe /d /s /c \"\"C:\\Program Files\\Codex\\codex.cmd\" app-server\""
            );
        }
    }
}

#[cfg(windows)]
fn main() {
    if let Err(error) = windows::run() {
        eprintln!("symphony-worker-host: {error}");
        std::process::exit(1);
    }
}
