MODULE faerie

USE ISO_C_BINDING
USE ISO_FORTRAN_ENV
USE NETCDF

IMPLICIT NONE

! Parameters
INTEGER, PARAMETER :: cd = C_DOUBLE
INTEGER, PARAMETER :: ci = C_INT
INTEGER, PARAMETER :: cb = C_BOOL
INTEGER, PARAMETER :: dp = REAL64
INTEGER, PARAMETER :: fi = INT32
REAL(dp), PARAMETER :: pi = ACOS(-1.0_dp)
REAL(dp), PARAMETER :: small = 1e-30_dp
REAL(dp), PARAMETER :: releps = 1.0e-6_dp
REAL(dp), PARAMETER :: rat53 = 5.0_dp/3.0_dp
REAL(dp), PARAMETER :: sqrt3 = SQRT(3.0_dp)
REAL(dp), PARAMETER :: sqrt5 = SQRT(5.0_dp)
CHARACTER(LEN=1), PARAMETER :: creturn = ACHAR(13)

! Kernel function interface
INTERFACE
  FUNCTION kernel(x1,x2)
    USE ISO_FORTRAN_ENV
    REAL(REAL64), DIMENSION(:), INTENT(IN) :: x1,x2
    REAL(REAL64) :: kernel
  END FUNCTION
END INTERFACE

! GP object
! single y output, zero prior mean, for now
TYPE gp_obj
  REAL(dp) :: noise, var ! Gaussian noise and kernel variance
  REAL(dp), DIMENSION(:), ALLOCATABLE :: il ! Inverse lengthscales
  REAL(dp), DIMENSION(:,:), ALLOCATABLE :: x ! Input samples
  REAL(dp), DIMENSION(:), ALLOCATABLE :: y ! Output samples
  INTEGER(fi) :: nx,nsamps ! Number of inputs and samples
  PROCEDURE(kernel), POINTER, NOPASS :: kern => NULL() ! Kernel function pointer
  !PROCEDURE(xconvert), POINTER, NOPASS :: xcon => NULL()
  !PROCEDURE(yconvert), POINTER, NOPASS :: ycon => NULL()
  !PROCEDURE(xrevert), POINTER, NOPASS :: xrev => NULL()
  !PROCEDURE(yrevert), POINTER, NOPASS :: yrev => NULL()
END TYPE
TYPE(gp_obj) :: gp

! Shared data
INTEGER(fi) :: i,j,info
REAL(dp), DIMENSION(:,:), ALLOCATABLE :: dist_bnds, y2d
REAL(dp), DIMENSION(:), ALLOCATABLE :: lowtri, alpha

CONTAINS

! Read in dataset, distributions, and gp params from NetCDF file
SUBROUTINE read_data()

  ! Known labels
  CHARACTER (LEN = *), PARAMETER :: fname = "gp.nc"
  CHARACTER (LEN = *), DIMENSION(4), PARAMETER :: &
    dimlabs = (/"inputs ","outputs","samples","bounds "/)
  CHARACTER (LEN = *), DIMENSION(4), PARAMETER :: &
    varlabs = (/"lengthscales  ","input_samples ","output_samples", &
                "dist_bounds   "/)

  ! IDs and lengths
  INTEGER :: fid,attlen
  INTEGER, DIMENSION(4) :: dimids, dimlens, varids

  ! Local output
  CHARACTER(:),ALLOCATABLE :: kern

  ! Open file
  CALL check(NF90_OPEN(fname, NF90_NOWRITE, fid))

  ! Get global attributes
  CALL check(NF90_INQUIRE_ATTRIBUTE(fid,NF90_GLOBAL,"kernel",len=attlen))
  ALLOCATE(CHARACTER(attlen)::kern)
  CALL check(NF90_GET_ATT(fid,NF90_GLOBAL,"kernel",kern))
  CALL check(NF90_GET_ATT(fid,NF90_GLOBAL,"var",gp%var))
  CALL check(NF90_GET_ATT(fid,NF90_GLOBAL,"noise",gp%noise))

  ! Get dimension/variable IDs and lengths
  DO i = 1, 4
    CALL check(NF90_INQ_DIMID(fid,TRIM(dimlabs(i)),dimids(i)))
    CALL check(NF90_INQUIRE_DIMENSION(fid,dimids(i),len=dimlens(i)))
    CALL check(NF90_INQ_VARID(fid,TRIM(varlabs(i)),varids(i)))
  END DO

  ! Read variables
  ALLOCATE(gp%il(dimlens(1)),gp%x(dimlens(1),dimlens(3)),y2d(dimlens(2),dimlens(3)))
  ALLOCATE(lowtri(dimlens(3)*(dimlens(3)+1)/2),dist_bnds(dimlens(4),dimlens(1)))
  ALLOCATE(gp%y(dimlens(3)),alpha(dimlens(3)))
  CALL check(NF90_GET_VAR(fid, varids(1), gp%il))
  CALL check(NF90_GET_VAR(fid, varids(2), gp%x))
  CALL check(NF90_GET_VAR(fid, varids(3), y2d))
  CALL check(NF90_GET_VAR(fid, varids(4), dist_bnds))

  ! Close file
  CALL check(NF90_CLOSE(fid))

  ! Assign GP function pointer and dimensions
  gp%nx = dimlens(1)
  gp%nsamps = dimlens(3)
  gp%il = 1/gp%il
  gp%y = y2d(1,:)
  IF (kern == "rbf") THEN
    gp%kern => rbf
  ELSE IF (kern == "Mat52") THEN
    gp%kern => matern52
  ELSE IF (kern == "Mat32") THEN
    gp%kern => matern32
  ELSE IF (kern == "Exponential") THEN
    gp%kern => exponential
  ELSE
    STOP "Read kernel name invalid: must be one of rbf, Mat52, Mat32, Exponential"
  END IF

  ! Deallocate temp arrays
  DEALLOCATE(kern,y2d)
  
END SUBROUTINE

! NetCDF status check
SUBROUTINE check(stat)

  INTEGER, INTENT(IN) :: stat

  IF(stat /= NF90_NOERR) then
    PRINT *, TRIM(NF90_STRERROR(stat))
    STOP "Stopped"
  END IF

END SUBROUTINE

! Evaluate covariance matrix for input samples dataset
SUBROUTINE data_covariances()

  INTEGER(fi) :: cnt

  ! Evaluate kernel at each unique combination of input data vectors
  ! In column order by lower triangle
  cnt = 1
  DO i = 1, gp%nsamps
    DO j = i, gp%nsamps
      lowtri(cnt) = gp%kern(gp%x(:,i),gp%x(:,j)) 
      ! Add noise on diagonal
      IF (i == j) THEN
        lowtri(cnt) = lowtri(cnt) + gp%noise
      END IF
      cnt = cnt + 1
    END DO
  END DO

END SUBROUTINE

! Use LAPACK Cholesky decomposition solver to obtain
! (K+v_nI)^-1.y and L (where K+v_nI = LL^T)
! For a fixed dataset these are also fixed
SUBROUTINE cholesky_solve()

  ! Copy alpha array with y to be overwritten 
  alpha = gp%y

  ! Obtain lower triangle of symmetric data covariance matrix
  CALL data_covariances()
  
  ! LAPACK Cholesky solve
  CALL dppsv('L',gp%nsamps,1,lowtri,alpha,gp%nsamps,info)

END SUBROUTINE

! Make predictions at new x points
SUBROUTINE predict()
  CONTINUE
END SUBROUTINE

! Kernel functions
FUNCTION rbf(x1,x2)
  REAL(dp), DIMENSION(:), INTENT(IN) :: x1,x2
  REAL(dp), DIMENSION(gp%nx) :: r
  REAL(dp) :: rbf
  r = x1 - x2
  rbf = gp%var*EXP(-0.5_dp*DOT_PRODUCT(r*gp%il**2,r))
END FUNCTION
FUNCTION matern52(x1,x2)
  REAL(dp), DIMENSION(:), INTENT(IN) :: x1,x2
  REAL(dp), DIMENSION(gp%nx) :: r
  REAL(dp) :: matern52, ril
  r = ABS(x1 - x2)
  ril = sqrt5*DOT_PRODUCT(r,gp%il)
  matern52 = gp%var*(1+ril+rat53*DOT_PRODUCT(r*gp%il**2,r))*EXP(-ril)
END FUNCTION
FUNCTION matern32(x1,x2)
  REAL(dp), DIMENSION(:), INTENT(IN) :: x1,x2
  REAL(dp), DIMENSION(gp%nx) :: r
  REAL(dp) :: matern32, ril
  r = ABS(x1 - x2)
  ril = sqrt3*DOT_PRODUCT(r,gp%il)
  matern32 = gp%var*(1+ril)*EXP(-ril)
END FUNCTION
FUNCTION exponential(x1,x2)
  REAL(dp), DIMENSION(:), INTENT(IN) :: x1,x2
  REAL(dp), DIMENSION(gp%nx) :: r
  REAL(dp) :: exponential, ril
  r = ABS(x1 - x2)
  ril = DOT_PRODUCT(r,gp%il)
  exponential = gp%var*EXP(-ril)
END FUNCTION

! x conversion/reversion functions
! only std_uniform for now

END MODULE

! Test program
PROGRAM main

  USE faerie

  CALL read_data()

  CALL cholesky_solve()

  PRINT *, alpha

  DEALLOCATE(gp%il,gp%x,gp%y,dist_bnds,lowtri)

END PROGRAM
